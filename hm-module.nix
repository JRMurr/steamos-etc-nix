{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.steamos-etc;
in
{
  options.programs.steamos-etc = {
    enable = lib.mkEnableOption "the steamos-etc command, which installs `files` into /etc";

    files = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = {
        "tmpfiles.d/example.conf" = "d /run/example 0755 root root -";
      };
      description = ''
        Files to keep under /etc, relative path -> content. Installed as real
        files, not store links, and added to SteamOS's atomic-update keep list.
      '';
    };

    waitForNix = lib.mkEnableOption ''
      a user@.service drop-in that holds the user session until /nix is
      mounted, so Home Manager's store links (environment.d, user-dirs.dirs)
      resolve at login
    '';

    gpuDrivers = lib.mkEnableOption ''
      /run/opengl-driver at boot through a tmpfiles rule, in place of
      `non-nixos-gpu-setup`
    '';

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = pkgs.callPackage ./package.nix { inherit (cfg) files; };
      description = "The steamos-etc command built from `files`.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [ cfg.package ];

        # Activation can't sudo, so it only warns. Catches what a switch alone
        # misses: rollbacks, a switch without steamos-etc, a SteamOS update
        # resetting /etc.
        home.activation.steamosEtcCheck = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
          if ! drift=$(${cfg.package}/bin/steamos-etc --check); then
            warnEcho "/etc differs from this generation:"
            while read -r line; do
              warnEcho "  $line"
            done <<< "$drift"
            warnEcho "To install it, run steamos-etc"
          fi
        '';
      }

      (lib.mkIf cfg.waitForNix {
        programs.steamos-etc.files."systemd/system/user@.service.d/nix.conf" = ''
          [Unit]
          Wants=nix.mount
          After=nix.mount
        '';
      })

      (lib.mkIf cfg.gpuDrivers {
        assertions = [
          {
            assertion = config.targets.genericLinux.enable;
            message = "programs.steamos-etc.gpuDrivers needs targets.genericLinux.enable.";
          }
        ];

        # tmpfiles creates the link even while /nix isn't mounted yet; a link to
        # this file in the store, as non-nixos-gpu-setup makes, would dangle.
        programs.steamos-etc.files."tmpfiles.d/non-nixos-gpu.conf" =
          "L+ /run/opengl-driver - - - - ${config.targets.genericLinux.gpu.drivers}";

        # Its hint points at non-nixos-gpu-setup.
        home.activation.checkExistingGpuDrivers = lib.mkForce (lib.hm.dag.entryAnywhere "");
      })
    ]
  );
}
