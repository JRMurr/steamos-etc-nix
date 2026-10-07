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

  # Services: one changes, one goes away, one stays and becomes wanted, one is new
  # and wanted, one is new and not wanted; plus a drop-in on a template (user@,
  # never restarted).
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
      "systemd/system/fresh.service" = "[Service]\nExecStart=/nix/store/fresh\n";
      "systemd/system/multi-user.target.d/fresh.conf" = "[Unit]\nWants=fresh.service\n";
      "systemd/system/manual.service" = "[Service]\nExecStart=/nix/store/manual\n";
    };
  };

  # A program copied from the store, with a mode and capabilities, then no longer declared.
  tool = pkgs.writeShellScript "tool" "echo tool";
  programBefore = pkgs.callPackage ../package.nix {
    files."example/tool" = {
      source = tool;
      mode = "0750";
      capabilities = [ "cap_net_raw" ];
    };
  };
  programAfter = pkgs.callPackage ../package.nix { files = { }; };

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

  # Services: restart what changed, stop what's gone, start what's newly wanted.
  export STEAMOS_ETC_ROOT=$PWD/units
  mkdir -p units/etc
  ${unitsBefore}/bin/steamos-etc > /dev/null
  ${unitsAfter}/bin/steamos-etc > units.out
  grep -E '^(try-restart|restart|start|stop) ' units.out > units.log || true
  grep -qx 'try-restart changed.service' units.log || fail "changed unit not restarted"
  grep -qx 'try-restart dropin.service' units.log || fail "unit with changed drop-in not restarted"
  grep -qx 'stop gone.service' units.log || fail "removed unit not stopped"
  grep -qx 'start kept.service' units.log || fail "newly wanted unit not started"
  grep -qx 'restart fresh.service' units.log || fail "new wanted unit not started"
  grep -qx 'try-restart manual.service' units.log || fail "new unwanted unit started"
  grep -q 'user@' units.log && fail "template unit restarted"
  grep -q 'multi-user' units.log && fail "target restarted"
  [[ $(wc -l < units.log) == 6 ]] || fail "unexpected actions: $(cat units.log)"

  # A copied program: a real file, its mode, its capabilities (recorded in a scratch root).
  export STEAMOS_ETC_ROOT=$PWD/program
  mkdir -p program/etc
  ${programBefore}/bin/steamos-etc > /dev/null
  [[ -L program/etc/example/tool ]] && fail "program installed as a link"
  cmp ${tool} program/etc/example/tool || fail "program content"
  [[ $(stat -c %a program/etc/example/tool) == 750 ]] || fail "program mode"
  grep -q '"cap_net_raw"' program/scratch-capabilities.json || fail "program capabilities"
  ${programBefore}/bin/steamos-etc --check || fail "program drift right after install"
  chmod 755 program/etc/example/tool
  ${programBefore}/bin/steamos-etc --check && fail "check missed a changed mode"
  ${programBefore}/bin/steamos-etc > /dev/null
  [[ $(stat -c %a program/etc/example/tool) == 750 ]] || fail "mode not repaired"
  ${programAfter}/bin/steamos-etc > /dev/null
  [[ -e program/etc/example/tool ]] && fail "undeclared program kept"
  grep -q cap_net_raw program/scratch-capabilities.json && fail "removed program's capabilities kept"

  touch $out
''
