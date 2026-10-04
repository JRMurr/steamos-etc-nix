# Sources the module's activation step against a scratch root
# (STEAMOS_ETC_ROOT), with warnEcho stubbed to record what it prints.
{ pkgs, home-manager }:
let
  home = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      ../hm-module.nix
      {
        home = {
          username = "deck";
          homeDirectory = "/home/deck";
          stateVersion = "25.05";
        };

        programs.steamos-etc = {
          enable = true;
          files."tmpfiles.d/demo.conf" = "d /run/demo 0755 root root -\n";
        };
      }
    ];
  };

  inherit (home.config.programs.steamos-etc) package;
  step = pkgs.writeText "steamos-etc-activation" home.config.home.activation.steamosEtcCheck.data;
in
pkgs.runCommand "steamos-etc-activation" { } ''
  set -euo pipefail
  export STEAMOS_ETC_ROOT=$PWD/root
  fail() { echo "FAIL: $*" >&2; exit 1; }
  warnEcho() { echo "$*" >> warnings; }

  mkdir -p root/etc
  source ${step}
  grep -q 'tmpfiles.d/demo.conf' warnings || fail "drifted file not named"
  grep -q 'run steamos-etc' warnings || fail "no hint to run steamos-etc"

  rm warnings
  ${package}/bin/steamos-etc
  source ${step}
  [[ ! -e warnings ]] || fail "warned on an up-to-date /etc: $(cat warnings)"

  touch $out
''
