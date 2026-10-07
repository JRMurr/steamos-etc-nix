"""Tests for the pure parts of steamos_etc.py. The CLI is covered by checks/sync.nix."""
import pytest
from hypothesis import given, strategies as st

import steamos_etc as se

NAMES = st.from_regex(r"[a-z][a-z0-9-]{0,8}", fullmatch=True)
UNITS = st.builds(lambda name, template, kind: f"{name}{'@' if template else ''}.{kind}",
                  NAMES, st.booleans(), st.sampled_from(["service", "target", "socket"]))


@given(UNITS, NAMES)
def test_service_of(unit, conf):
    expected = unit if unit.endswith(".service") and not se.is_template(unit) else None
    assert se.service_of(f"systemd/system/{unit}") == expected
    assert se.service_of(f"systemd/system/{unit}.d/{conf}.conf") == expected


@given(UNITS, NAMES)
def test_target_of(unit, conf):
    expected = unit if unit.endswith(".target") else None
    assert se.target_of(f"systemd/system/{unit}.d/{conf}.conf") == expected
    assert se.target_of(f"systemd/system/{unit}") is None


@given(st.lists(st.lists(UNITS, min_size=1), max_size=4), st.lists(UNITS, max_size=3))
def test_pulled_in(wants_lines, after):
    text = "[Unit]\n"
    text += "".join(f"Wants={' '.join(units)}\n" for units in wants_lines)
    text += "".join(f"After={unit}\n" for unit in after)

    named = {unit for units in wants_lines for unit in units}
    assert se.pulled_in(text) == {unit for unit in named if not se.is_template(unit)}


def test_pulled_in_requires():
    assert se.pulled_in("[Unit]\nRequires=a.service\nWants=b.service c@.service\n") == {"a.service", "b.service"}


CAPS = st.lists(st.sampled_from(["cap_sys_ptrace", "cap_perfmon", "cap_dac_read_search", "cap_chown"]),
                unique=True, min_size=1)


@given(CAPS)
def test_parse_getcap(caps):
    """libcap's two output forms; anything but effective and permitted is a mismatch."""
    path = "/etc/frametop/ft-camd"
    assert se.parse_getcap(f"{path} {','.join(caps)}=ep\n") == frozenset(caps)
    assert se.parse_getcap(f"{path} = {','.join(caps)}+ep\n") == frozenset(caps)
    assert se.parse_getcap(f"{path} {','.join(caps)}=eip\n") is None


def test_parse_getcap_none():
    assert se.parse_getcap("") == frozenset()


def test_etc_needs_a_caps_backend(tmp_path):
    """No default: a live /etc without LiveCaps would record capabilities instead of setting them."""
    with pytest.raises(TypeError):
        se.Etc(tmp_path)
    assert se.Etc(tmp_path, se.ScratchCaps(tmp_path)).caps.file == tmp_path / se.SCRATCH_CAPS
