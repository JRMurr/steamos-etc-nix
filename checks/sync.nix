# Drives steamos-etc against a scratch root (STEAMOS_ETC_ROOT), which also skips
# the sudo re-exec and the systemd side effects.
{ pkgs }:
let
  before = pkgs.callPackage ../package.nix {
    files = {
      "tmpfiles.d/gpu.conf" = "L+ /run/opengl-driver - - - - /nix/store/old\n";
      "systemd/system/user@.service.d/nix.conf" = "[Unit]\nAfter=nix.mount\n";
    };
  };

  after = pkgs.callPackage ../package.nix {
    files."tmpfiles.d/gpu.conf" = "L+ /run/opengl-driver - - - - /nix/store/new\n";
  };

  # Services: one changes, one goes away, one stays; plus drop-ins on a template
  # (user@, never restarted) and on a target (not a service).
  unitsBefore = pkgs.callPackage ../package.nix {
    files = {
      "systemd/system/changed.service" = "[Service]\nExecStart=/nix/store/old\n";
      "systemd/system/dropin.service.d/x.conf" = "[Service]\nNice=1\n";
      "systemd/system/kept.service" = "[Service]\nExecStart=/nix/store/kept\n";
      "systemd/system/gone.service" = "[Service]\nExecStart=/nix/store/gone\n";
    };
  };

  unitsAfter = pkgs.callPackage ../package.nix {
    files = {
      "systemd/system/changed.service" = "[Service]\nExecStart=/nix/store/new\n";
      "systemd/system/dropin.service.d/x.conf" = "[Service]\nNice=2\n";
      "systemd/system/kept.service" = "[Service]\nExecStart=/nix/store/kept\n";
      "systemd/system/user@.service.d/nix.conf" = "[Unit]\nAfter=nix.mount\n";
      "systemd/system/multi-user.target.d/kept.conf" = "[Unit]\nWants=kept.service\n";
    };
  };

  keepList = "root/etc/atomic-update.conf.d/steamos-etc.conf";
in
pkgs.runCommand "steamos-etc-sync" { } ''
  set -euo pipefail
  export STEAMOS_ETC_ROOT=$PWD/root
  fail() { echo "FAIL: $*" >&2; exit 1; }

  mkdir -p root/etc/tmpfiles.d
  echo keep > root/etc/unmanaged.conf
  # What non-nixos-gpu-setup leaves behind: a link into the store.
  echo stale > store-target
  ln -s $PWD/store-target root/etc/tmpfiles.d/gpu.conf

  ${before}/bin/steamos-etc --check && fail "check passed before install"

  ${before}/bin/steamos-etc
  [[ -L root/etc/tmpfiles.d/gpu.conf ]] && fail "symlink not replaced"
  grep -q /nix/store/old root/etc/tmpfiles.d/gpu.conf || fail "gpu.conf content"
  [[ $(cat store-target) == stale ]] || fail "wrote through the old symlink"
  grep -q nix.mount 'root/etc/systemd/system/user@.service.d/nix.conf' || fail "drop-in missing"
  ${before}/bin/steamos-etc --check || fail "check failed right after install"

  grep -qx /etc/tmpfiles.d/gpu.conf ${keepList} || fail "file not on keep list"
  grep -qx /etc/steamos-etc/manifest ${keepList} || fail "manifest not on keep list"
  grep -qx /etc/atomic-update.conf.d/steamos-etc.conf ${keepList} || fail "keep list not on itself"

  echo edited > root/etc/tmpfiles.d/gpu.conf
  ${before}/bin/steamos-etc --check && fail "check missed a local edit"
  ${before}/bin/steamos-etc
  ${before}/bin/steamos-etc --check || fail "edit not repaired"

  ${after}/bin/steamos-etc --check && fail "check missed a stale file"
  ${after}/bin/steamos-etc
  grep -q /nix/store/new root/etc/tmpfiles.d/gpu.conf || fail "gpu.conf not updated"
  [[ -e 'root/etc/systemd/system/user@.service.d/nix.conf' ]] && fail "stale drop-in kept"
  grep -q nix.conf ${keepList} && fail "stale file still on keep list"
  [[ $(cat root/etc/unmanaged.conf) == keep ]] || fail "unmanaged file touched"
  ${after}/bin/steamos-etc --check || fail "not idempotent"
  [[ $(${after}/bin/steamos-etc) == "/etc up to date" ]] || fail "rewrote an up-to-date /etc"

  # Services: restart what changed, stop what's gone, leave the rest.
  export STEAMOS_ETC_ROOT=$PWD/units
  mkdir -p units/etc
  ${unitsBefore}/bin/steamos-etc > /dev/null
  ${unitsAfter}/bin/steamos-etc > units.out
  grep -E '^(try-restart|stop) ' units.out > units.log || true
  grep -qx 'try-restart changed.service' units.log || fail "changed unit not restarted"
  grep -qx 'try-restart dropin.service' units.log || fail "unit with changed drop-in not restarted"
  grep -qx 'stop gone.service' units.log || fail "removed unit not stopped"
  grep -q 'kept.service' units.log && fail "unchanged unit touched"
  grep -q 'user@' units.log && fail "template unit restarted"
  grep -q 'multi-user' units.log && fail "target restarted"
  [[ $(wc -l < units.log) == 3 ]] || fail "unexpected actions: $(cat units.log)"

  touch $out
''
