# Renders `services` through the module and compares the files it produces.
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
          services.demo = {
            Unit = {
              Description = "Demo daemon";
              After = [
                "network-pre.target"
                "systemd-resolved.service"
              ];
            };
            Service = {
              ExecStart = [
                ""
                "/nix/store/demo/bin/demo --flag"
              ];
              Restart = "on-failure";
              RemainAfterExit = true;
              RestartSec = 3;
              Environment = [ ];
            };
            Install = {
              WantedBy = [ "multi-user.target" ];
              RequiredBy = [ "demo-consumer.service" ];
            };
          };
        };
      }
    ];
  };

  inherit (home.config.programs.steamos-etc) files;

  expected = {
    "systemd/system/demo.service" = ''
      [Service]
      ExecStart=
      ExecStart=/nix/store/demo/bin/demo --flag
      RemainAfterExit=true
      Restart=on-failure
      RestartSec=3

      [Unit]
      After=network-pre.target
      After=systemd-resolved.service
      Description=Demo daemon
      RequiresMountsFor=/nix/store
    '';
    "systemd/system/multi-user.target.d/demo.conf" = ''
      [Unit]
      Wants=demo.service
    '';
    "systemd/system/demo-consumer.service.d/demo.conf" = ''
      [Unit]
      Requires=demo.service
    '';
  };

  mismatches = builtins.filter (path: (files.${path} or null) != expected.${path}) (
    builtins.attrNames expected
  );

  report = pkgs.lib.concatMapStrings (path: ''
    --- ${path}: expected
    ${expected.${path}}
    --- got
    ${files.${path} or "(missing)"}
  '') mismatches;
in
pkgs.runCommand "steamos-etc-services" { } ''
  ${
    if mismatches == [ ] then
      ""
    else
      ''
        cat <<'EOF' >&2
        ${report}
        EOF
        exit 1
      ''
  }
  touch $out
''
