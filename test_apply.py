"""Property tests for check() and apply(): random sequences of generations applied to
a scratch /etc, with systemd actions recorded instead of run."""
import contextlib
import io
import tempfile
from pathlib import Path

from hypothesis import example, given, settings, strategies as st

import steamos_etc as se

SERVICES = ["a.service", "b.service"]
TEMPLATE = "t@.service"

# A small pool, so generations overlap: the same path changes, stays, or goes.
UNIT_FILES = [f"systemd/system/{unit}" for unit in SERVICES + [TEMPLATE]]
SERVICE_DROP_INS = ["systemd/system/a.service.d/x.conf", f"systemd/system/{TEMPLATE}.d/x.conf"]
TARGET_DROP_INS = [
    "systemd/system/multi-user.target.d/a.conf",
    "systemd/system/multi-user.target.d/b.conf",
    "systemd/system/timers.target.d/a.conf",
]
OTHER_FILES = ["tmpfiles.d/a.conf", "tmpfiles.d/b.conf"]
# Copies of programs: their mode and capabilities are declared too.
PROGRAMS = ["frametop/ft-camd", "frametop/ft-eyegrab"]
MODES = [0o644, 0o755, 0o700]
CAPABILITIES = [[], ["cap_sys_ptrace"], ["cap_perfmon", "cap_sys_ptrace"]]

UNMANAGED = "unmanaged.conf"
UNMANAGED_TEXT = "keep\n"


def drop_in_text(units):
    return f"[Unit]\nWants={' '.join(units)}\n" if units else "[Unit]\n"


def plain_contents():
    return st.sampled_from(["one\n", "two\n"])


def target_contents():
    return st.lists(st.sampled_from(SERVICES + [TEMPLATE]), unique=True, max_size=3).map(drop_in_text)


@st.composite
def generations(draw):
    """path -> content, and path -> attributes (mode, capabilities), for one generation."""
    files, attributes = {}, {}
    for path in UNIT_FILES + SERVICE_DROP_INS + OTHER_FILES + PROGRAMS:
        if draw(st.booleans()):
            files[path] = draw(plain_contents())
    for path in TARGET_DROP_INS:
        if draw(st.booleans()):
            files[path] = draw(target_contents())
    for path in PROGRAMS:
        if path in files:
            attributes[path] = {"mode": draw(st.sampled_from(MODES)),
                                "capabilities": draw(st.sampled_from(CAPABILITIES))}
    return files, attributes


class Recorder(se.Systemd):
    def __init__(self):
        super().__init__(se.Mode.SCRATCH)
        self.actions = []

    def act(self, action, unit):
        self.actions.append((action, unit))


def write_tree(directory, files):
    for path, text in files.items():
        (directory / path).parent.mkdir(parents=True, exist_ok=True)
        (directory / path).write_text(text)


def run_apply(etc, tree, attributes):
    se.TREE = tree
    se.ATTRIBUTES = attributes
    systemd = Recorder()
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        se.apply(etc, systemd)
    return systemd.actions, out.getvalue()


def service_of_unit_file(path):
    unit = se.service_of(path)
    return unit if unit and path.endswith(".service") else None


def changed_paths(before, after):
    return {p for p in after if before.get(p) != after[p]} | (before.keys() - after.keys())


def assert_installed(etc, files, attributes):
    assert etc.drift() == []
    for path, text in files.items():
        installed = etc.dir / path
        assert not installed.is_symlink()
        assert installed.read_text() == text
        declared = attributes.get(path, {})
        assert installed.stat().st_mode & 0o7777 == declared.get("mode", se.DEFAULT_MODE)
        assert etc.caps.get(installed) == frozenset(declared.get("capabilities", []))
    assert (etc.dir / UNMANAGED).read_text() == UNMANAGED_TEXT


def assert_actions(actions, before, after):
    acted = [unit for _, unit in actions]
    assert len(acted) == len(set(acted)), f"a unit got two actions: {actions}"
    assert not any(se.is_template(unit) or unit.endswith(".target") for unit in acted)

    removed = {service_of_unit_file(p) for p in before.keys() - after.keys()} - {None}
    stopped = {unit for action, unit in actions if action == se.UnitAction.STOP}
    assert stopped == removed

    changed = changed_paths(before, after)
    wanted = set()
    for path in changed & after.keys():
        if se.target_of(path):
            wanted |= se.pulled_in(after[path])
    # A removed unit can't start, even if a drop-in still wants it.
    wanted -= removed
    started = {unit for action, unit in actions if action in (se.UnitAction.START, se.UnitAction.RESTART)}
    assert wanted <= started

    touched = {se.service_of(p) for p in changed} - {None}
    assert set(acted) <= touched | wanted


@settings(max_examples=200, deadline=None)
# Found by this test: a service and its drop-in removed together were stopped,
# then try-restarted, which fails once the unit file is gone.
@example(
    gens=[({"systemd/system/a.service": "one\n", "systemd/system/a.service.d/x.conf": "one\n"}, {}), ({}, {})],
    planted="tmpfiles.d/a.conf",
)
@given(st.lists(generations(), min_size=1, max_size=4), st.sampled_from(OTHER_FILES + UNIT_FILES))
def test_apply_sequence(gens, planted):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        se.MANIFEST = "steamos-etc/manifest"
        etc = se.Etc(tmp / "root")
        etc.dir.mkdir(parents=True)
        (etc.dir / UNMANAGED).write_text(UNMANAGED_TEXT)

        # What non-nixos-gpu-setup leaves: a link where a declared file goes.
        target = tmp / "store-target"
        target.write_text("stale\n")
        (etc.dir / planted).parent.mkdir(parents=True, exist_ok=True)
        (etc.dir / planted).symlink_to(target)

        before = {}
        for n, (files, attributes) in enumerate(gens):
            tree = tmp / f"tree-{n}"
            tree.mkdir()
            write_tree(tree, files)

            actions, _ = run_apply(etc, tree, attributes)

            assert_installed(etc, files, attributes)
            for path in before.keys() - files.keys():
                assert not (etc.dir / path).exists()
            assert_actions(actions, before, files)

            actions, out = run_apply(etc, tree, attributes)
            assert out == "/etc up to date\n"
            assert actions == []

            before = files

        assert target.read_text() == "stale\n", "wrote through the planted link"


@settings(max_examples=50, deadline=None)
@given(st.sampled_from(MODES), st.sampled_from(CAPABILITIES[1:]), st.sampled_from(["mode", "capabilities"]))
def test_attributes_drift(mode, capabilities, tamper):
    """A copy whose mode or capabilities changed after it was installed is drift, and gets
    them back."""
    path = PROGRAMS[0]
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        se.MANIFEST = "steamos-etc/manifest"
        etc = se.Etc(tmp / "root")
        etc.dir.mkdir(parents=True)
        (etc.dir / UNMANAGED).write_text(UNMANAGED_TEXT)
        tree = tmp / "tree"
        tree.mkdir()
        files, attributes = {path: "one\n"}, {path: {"mode": mode, "capabilities": capabilities}}
        write_tree(tree, files)
        run_apply(etc, tree, attributes)

        installed = etc.dir / path
        if tamper == "mode":
            installed.chmod(mode ^ 0o111)
        else:
            etc.caps.set(installed, frozenset())
        assert etc.drift() == [f"differs: /etc/{path}"]

        run_apply(etc, tree, attributes)
        assert_installed(etc, files, attributes)
