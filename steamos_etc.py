"""steamos-etc: install the declared /etc files, remove ones no longer declared.

STEAMOS_ETC_ROOT points /etc somewhere else, for tests: no sudo, no systemd, and file
capabilities recorded in a file there instead of set.
"""
import argparse
import enum
import filecmp
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Substituted by package.nix.
TREE = Path("@tree@")
MANIFEST = "@manifest@"
ATTRIBUTES_FILE = Path("@attributes@")  # path -> {"mode": "0755", "capabilities": [...]}
GETCAP = "@getcap@"
SETCAP = "@setcap@"

# path -> {"mode": int, "capabilities": [names]}, for files that declare them (main loads it).
ATTRIBUTES = {}
DEFAULT_MODE = 0o644
SCRATCH_CAPS = "scratch-capabilities.json"  # beside a scratch root's etc/

GCROOT = Path("/nix/var/nix/gcroots/steamos-etc")

SERVICE_DROP_IN = re.compile(r"^systemd/system/([^/]+\.service)\.d/[^/]+$")
SERVICE_UNIT = re.compile(r"^systemd/system/([^/]+\.service)$")
TARGET_DROP_IN = re.compile(r"^systemd/system/([^/]+\.target)\.d/[^/]+$")
PULLS_IN = re.compile(r"^(?:Wants|Requires)=(.*)$", re.MULTILINE)


class Mode(enum.Enum):
    LIVE = "live"  # the real /etc, with sudo and systemd
    SCRATCH = "scratch"  # STEAMOS_ETC_ROOT: files only, systemd actions printed


class UnitAction(enum.StrEnum):
    START = "start"
    RESTART = "restart"
    TRY_RESTART = "try-restart"
    STOP = "stop"


def is_template(unit):
    return "@." in unit


def service_of(path):
    """The service a unit file or drop-in belongs to, if it's one we may restart.
    Templates are left alone: user@.service is the whole user session."""
    match = SERVICE_DROP_IN.match(path) or SERVICE_UNIT.match(path)
    if not match or is_template(match[1]):
        return None
    return match[1]


def target_of(path):
    """The target a drop-in extends, for drop-ins on targets."""
    match = TARGET_DROP_IN.match(path)
    return match[1] if match else None


def pulled_in(text):
    """The units a drop-in pulls in (Wants=, Requires=), templates excluded. One
    line can name several units: Wants=a.service b.service"""
    units = (unit for line in PULLS_IN.findall(text) for unit in line.split())
    return {unit for unit in units if not is_template(unit)}


class Systemd:
    """systemctl, or in SCRATCH mode a printout of what would run."""

    def __init__(self, mode):
        self.mode = mode

    def run(self, *args):
        if self.mode == Mode.LIVE:
            subprocess.run(args, check=True)

    def reload(self):
        self.run("systemctl", "daemon-reload")

    def is_active(self, unit):
        """Without systemd, every unit counts as up."""
        if self.mode == Mode.SCRATCH:
            return True
        result = subprocess.run(["systemctl", "is-active", "--quiet", unit])
        return result.returncode == 0

    def act(self, action, unit):
        print(f"{action} {unit}")
        self.run("systemctl", str(action), unit)

    def create_tmpfiles(self, paths):
        if paths:
            self.run("systemd-tmpfiles", "--create", *map(str, paths))


def parse_getcap(output):
    """getcap's capabilities for one file: effective and permitted ones, as names. Empty for
    none; None for any other flags, which never match a declaration."""
    words = output.split()
    if not words:
        return frozenset()
    # "PATH cap_a,cap_b=ep", or older libcap's "PATH = cap_a,cap_b+ep"
    spec, sep = (words[2], "+") if len(words) >= 3 and words[1] == "=" else (words[1], "=")
    names, _, flags = spec.rpartition(sep)
    if flags != "ep":
        return None
    return frozenset(names.split(","))


class LiveCaps:
    """File capabilities through libcap's getcap and setcap."""

    def get(self, path):
        out = subprocess.run([GETCAP, str(path)], capture_output=True, text=True, check=True).stdout
        return parse_getcap(out)

    def set(self, path, caps):
        if caps:
            subprocess.run([SETCAP, ",".join(sorted(caps)) + "+ep", str(path)], check=True)
        else:
            subprocess.run([SETCAP, "-r", str(path)], capture_output=True)  # fails if it had none

    def forget(self, path):
        """A removed file's capabilities went with it."""


class ScratchCaps:
    """File capabilities recorded in a JSON file beside a scratch root's etc/: setting real
    ones needs root."""

    def __init__(self, root):
        self.file = root / SCRATCH_CAPS

    def load(self):
        return json.loads(self.file.read_text()) if self.file.is_file() else {}

    def get(self, path):
        return frozenset(self.load().get(str(path), []))

    def set(self, path, caps):
        recorded = self.load()
        recorded[str(path)] = sorted(caps)
        self.file.parent.mkdir(parents=True, exist_ok=True)
        self.file.write_text(json.dumps(recorded))

    def forget(self, path):
        """A removed file's capabilities go with it, as real ones do."""
        self.set(path, frozenset())


def declared(path):
    """A file's declared mode and capabilities."""
    attributes = ATTRIBUTES.get(path, {})
    return attributes.get("mode", DEFAULT_MODE), frozenset(attributes.get("capabilities", []))


def load_attributes(file):
    """ATTRIBUTES_FILE, with its octal mode strings as numbers."""
    return {path: {"mode": int(a["mode"], 8), "capabilities": a["capabilities"]}
            for path, a in json.loads(file.read_text()).items()}


class Etc:
    def __init__(self, root, caps):
        """caps: LiveCaps for the real /etc, ScratchCaps for a scratch root."""
        self.dir = root / "etc"
        self.manifest = self.dir / MANIFEST
        self.caps = caps

    def managed(self):
        """Relative paths of every declared file, sorted."""
        found = []
        for dirpath, _, filenames in os.walk(TREE, followlinks=True):
            for name in filenames:
                found.append(os.path.relpath(os.path.join(dirpath, name), TREE))
        return sorted(found)

    def stale(self):
        """Files installed before that are no longer declared."""
        if not self.manifest.is_file():
            return []
        installed = self.manifest.read_text().splitlines()
        return sorted(set(installed) - set(self.managed()))

    def is_current(self, path):
        """A symlink counts as drift even with the right content: its target may
        not be mounted yet when the file is needed. So do a changed mode and
        changed capabilities."""
        installed = self.dir / path
        if installed.is_symlink() or not installed.is_file():
            return False
        if not filecmp.cmp(TREE / path, installed, shallow=False):
            return False
        mode, caps = declared(path)
        if installed.stat().st_mode & 0o7777 != mode:
            return False
        return self.caps.get(installed) == caps

    def drift(self):
        differs = [f"differs: /etc/{p}" for p in self.managed() if not self.is_current(p)]
        stale = [f"stale: /etc/{p}" for p in self.stale()]
        return differs + stale

    def install(self, path):
        """Removed first: writing in place would go through a symlink into the store."""
        installed = self.dir / path
        installed.unlink(missing_ok=True)
        installed.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(TREE / path, installed)
        mode, caps = declared(path)
        installed.chmod(mode)
        self.caps.set(installed, caps)  # after the content: writing a file clears them
        print(f"installed /etc/{path}")

    def remove(self, path):
        (self.dir / path).unlink(missing_ok=True)
        self.caps.forget(self.dir / path)
        print(f"removed /etc/{path}")

    def write_manifest(self):
        self.manifest.parent.mkdir(parents=True, exist_ok=True)
        self.manifest.write_text("".join(f"{p}\n" for p in self.managed()))


def check(etc):
    drift = etc.drift()
    for line in drift:
        print(line)
    return 1 if drift else 0


def apply(etc, systemd):
    if not etc.drift():
        print("/etc up to date")
        return 0

    if systemd.mode == Mode.LIVE and os.geteuid() != 0:
        os.execvp("sudo", ["sudo", os.path.realpath(sys.argv[0])])

    tmpfiles = []
    changed = set()
    stopped = set()
    target_drop_ins = []

    for path in etc.managed():
        if etc.is_current(path):
            continue

        etc.install(path)
        if path.startswith("tmpfiles.d/"):
            tmpfiles.append(etc.dir / path)
        if unit := service_of(path):
            changed.add(unit)
        if target := target_of(path):
            target_drop_ins.append((target, path))

    for path in etc.stale():
        # Stopped while its unit file still exists. A removed drop-in only
        # changes its service, unless that service went too.
        unit = service_of(path)
        if unit and path.endswith(".service"):
            systemd.act(UnitAction.STOP, unit)
            stopped.add(unit)
        elif unit:
            changed.add(unit)
        etc.remove(path)

    # A stopped service's unit file is gone: restarting or starting it would fail.
    changed -= stopped

    etc.write_manifest()
    systemd.reload()

    # What a new or changed target drop-in pulls in starts now, as it would at
    # boot, if that target is up.
    wanted = set()
    for target, path in target_drop_ins:
        if systemd.is_active(target):
            wanted |= pulled_in((etc.dir / path).read_text())
    wanted -= stopped

    # Changed services: running ones pick up the new unit (try-restart); stopped
    # ones stay stopped unless a target wants them (restart starts them too).
    for unit in sorted(changed - wanted):
        systemd.act(UnitAction.TRY_RESTART, unit)
    for unit in sorted(wanted):
        systemd.act(UnitAction.RESTART if unit in changed else UnitAction.START, unit)

    if systemd.mode == Mode.SCRATCH:
        return 0

    # Root the tree: the files reference store paths (GPU drivers) that must
    # outlive the Home Manager generation that built them.
    link = GCROOT.with_name(GCROOT.name + ".new")
    link.unlink(missing_ok=True)
    link.symlink_to(TREE)
    link.replace(GCROOT)

    systemd.create_tmpfiles(tmpfiles)
    return 0


def main():
    parser = argparse.ArgumentParser(
        prog="steamos-etc",
        description="Install the declared /etc files, remove ones no longer declared.",
    )
    parser.add_argument("--check", action="store_true", help="only report drift; exits 1 if there is any")
    args = parser.parse_args()

    global ATTRIBUTES
    ATTRIBUTES = load_attributes(ATTRIBUTES_FILE)

    scratch = os.environ.get("STEAMOS_ETC_ROOT")
    mode = Mode.SCRATCH if scratch else Mode.LIVE
    root = Path(scratch or "/")
    etc = Etc(root, ScratchCaps(root) if scratch else LiveCaps())

    if args.check:
        return check(etc)
    return apply(etc, Systemd(mode))


if __name__ == "__main__":
    sys.exit(main())
