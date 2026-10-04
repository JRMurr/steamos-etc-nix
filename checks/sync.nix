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

  touch $out
''
