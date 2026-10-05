"""steamos-etc: install the declared /etc files, remove ones no longer declared.

STEAMOS_ETC_ROOT points /etc somewhere else, for tests: no sudo, no systemd.
"""
import argparse
import enum
import filecmp
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Substituted by package.nix.
TREE = Path("@tree@")
MANIFEST = "@manifest@"

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


class Etc:
    def __init__(self, root):
        self.dir = root / "etc"
        self.manifest = self.dir / MANIFEST

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
        not be mounted yet when the file is needed."""
        installed = self.dir / path
        if installed.is_symlink() or not installed.is_file():
            return False
        return filecmp.cmp(TREE / path, installed, shallow=False)

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
        installed.chmod(0o644)
        print(f"installed /etc/{path}")

    def remove(self, path):
        (self.dir / path).unlink(missing_ok=True)
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
        # changes its service, which stays.
        unit = service_of(path)
        if unit and path.endswith(".service"):
            systemd.act(UnitAction.STOP, unit)
            changed.discard(unit)
        elif unit:
            changed.add(unit)
        etc.remove(path)

    etc.write_manifest()
    systemd.reload()

    # What a new or changed target drop-in pulls in starts now, as it would at
    # boot, if that target is up.
    wanted = set()
    for target, path in target_drop_ins:
        if systemd.is_active(target):
            wanted |= pulled_in((etc.dir / path).read_text())

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

    scratch = os.environ.get("STEAMOS_ETC_ROOT")
    mode = Mode.SCRATCH if scratch else Mode.LIVE
    etc = Etc(Path(scratch or "/"))

    if args.check:
        return check(etc)
    return apply(etc, Systemd(mode))


if __name__ == "__main__":
    sys.exit(main())
