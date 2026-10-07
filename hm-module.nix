{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.steamos-etc;

  unitAtom = lib.types.oneOf [
    lib.types.bool
    lib.types.int
    lib.types.str
    lib.types.path
  ];
  unitType = lib.types.attrsOf (
    lib.types.attrsOf (lib.types.either unitAtom (lib.types.listOf unitAtom))
  );

  # Home Manager's rendering for user units: lists become repeated keys.
  toSystemdIni = lib.generators.toINI {
    listsAsDuplicateKeys = true;
    mkKeyValue =
      key: value:
      let
        value' = if lib.isBool value then lib.boolToString value else toString value;
      in
      "${key}=${value'}";
  };

  # [Install] -> the dependency each key becomes in a drop-in on its target.
  installDeps = {
    WantedBy = "Wants";
    RequiredBy = "Requires";
  };

  # Units run from the store, and SteamOS starts system units before nix.mount.
  waitForStore =
    unit:
    unit
    // {
      Unit = (unit.Unit or { }) // {
        RequiresMountsFor = lib.toList (unit.Unit.RequiresMountsFor or [ ]) ++ [ "/nix/store" ];
      };
    };

  # A file given as more than text: a copy of a store path, its mode, file capabilities.
  fileType = lib.types.submodule {
    options = {
      text = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = null;
        description = "The file's content. Set this or `source`.";
      };
      source = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "A file to copy, such as a program from the store. Set this or `text`.";
      };
      mode = lib.mkOption {
        type = lib.types.strMatching "0?[0-7]{3,4}";
        default = "0644";
        description = "The file's mode, in octal.";
      };
      capabilities = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "cap_sys_ptrace" ];
        description = ''
          File capabilities, effective and permitted (setcap NAMES+ep). A copy of a
          program can carry them; a store path can't.
        '';
      };
    };
  };

  dropUnset = lib.mapAttrs (_: lib.filterAttrs (_: value: value != [ ]));

  serviceFiles =
    name: unit:
    let
      unitName = "${name}.service";
      install = unit.Install or { };

      body = lib.filterAttrs (_: section: section != { }) (
        dropUnset (waitForStore (removeAttrs unit [ "Install" ]))
      );

      # `systemctl enable` would link the unit into <target>.wants, but SteamOS
      # updates keep only regular files. A drop-in on the target does the same.
      dropIns = lib.concatMapAttrs (
        key: dep:
        lib.listToAttrs (
          map (target: {
            name = "systemd/system/${target}.d/${name}.conf";
            value = toSystemdIni { Unit.${dep} = unitName; };
          }) (install.${key} or [ ])
        )
      ) installDeps;
    in
    { "systemd/system/${unitName}" = toSystemdIni body; } // dropIns;
in
{
  options.programs.steamos-etc = {
    enable = lib.mkEnableOption "the steamos-etc command, which installs `files` into /etc";

    files = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines fileType);
      default = { };
      example = lib.literalExpression ''
        {
          "tmpfiles.d/example.conf" = "d /run/example 0755 root root -";
          "example/tool" = {
            source = "''${pkgs.example}/bin/tool";
            mode = "0755";
            capabilities = [ "cap_net_raw" ];
          };
        }
      '';
      description = ''
        Files to keep under /etc, relative path -> content, or a file copied from
        `source` with a `mode` and file `capabilities`. Installed as real files, not
        store links, and added to SteamOS's atomic-update keep list.
      '';
    };

    services = lib.mkOption {
      type = lib.types.attrsOf unitType;
      default = { };
      example = lib.literalExpression ''
        {
          tailscaled = {
            Unit.Description = "Tailscale node agent";
            Service.ExecStart = "''${pkgs.tailscale}/bin/tailscaled";
            Install.WantedBy = [ "multi-user.target" ];
          };
        }
      '';
      description = ''
        System services, in the same shape as Home Manager's
        `systemd.user.services`. Each becomes a unit in /etc/systemd/system with
        `RequiresMountsFor=/nix/store` added. `Install.WantedBy` and
        `Install.RequiredBy` become drop-ins on their targets instead of the
        symlinks `systemctl enable` makes, since SteamOS updates keep only
        regular files; other `Install` keys aren't supported.
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

      # TODO: timers and sockets, the same way as services.
      {
        assertions =
          lib.mapAttrsToList (name: unit: {
            assertion = builtins.all (key: installDeps ? ${key}) (builtins.attrNames (unit.Install or { }));
            message = "programs.steamos-etc.services.${name}.Install: only WantedBy and RequiredBy are supported.";
          }) cfg.services
          ++ lib.mapAttrsToList (path: file: {
            assertion = builtins.isString file || (file.text == null) != (file.source == null);
            message = "programs.steamos-etc.files.\"${path}\": set one of text and source.";
          }) cfg.files;

        programs.steamos-etc.files = lib.concatMapAttrs serviceFiles cfg.services;
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
