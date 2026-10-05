# steamos-etc-nix

Declarative `/etc` files for standalone Home Manager on SteamOS (Steam Deck, Steam Frame).

Home Manager can't write `/etc`. This flake adds a `steamos-etc` command that installs the files you declare there. It runs after `home-manager switch` and asks for `sudo` only when something differs.

## Why

SteamOS has two traits that break the usual approaches:

- **Updates replace the root.** `/etc` is a writable overlay kept under `/var`, but updates drop any file missing from a keep list in `/etc/atomic-update.conf.d/`.
- **`/nix` mounts late.** The Nix installer's `steam-deck` planner keeps the store in `/home/nix` and bind-mounts it with `nix.mount`. tmpfiles and the user session start before that mount, so any store link they read dangles.

`steamos-etc` therefore:

- installs real files, never store links, and replaces any existing link;
- writes `/etc/atomic-update.conf.d/steamos-etc.conf`, listing every file it manages;
- removes files you stop declaring, tracked in `/etc/steamos-etc/manifest`;
- adds a gcroot, `/nix/var/nix/gcroots/steamos-etc`, so store paths the files mention outlive their generation;
- reloads systemd and applies changed tmpfiles rules;
- restarts running services whose unit or `.service.d` drop-in changed, and stops services whose unit it removes. Template units (`user@.service`) are never restarted.

## Usage

```nix
# flake.nix
inputs.steamos-etc.url = "github:JRMurr/steamos-etc-nix";
```

```nix
# home.nix
{ inputs, ... }:
{
  imports = [ inputs.steamos-etc.homeManagerModules.default ];

  targets.genericLinux.enable = true;

  programs.steamos-etc = {
    enable = true;
    waitForNix = true;
    gpuDrivers = true;

    files."tmpfiles.d/my-cache.conf" = "d /var/cache/my-app 0755 root root -";
  };
}
```

Then switch and sync:

```bash
home-manager switch --flake ~/nix-config && steamos-etc
```

`steamos-etc --check` reports drift without changing anything and exits 1 if there is any.

Activation runs the same check and warns with the list of differing files. Activation can't use `sudo`, so it only warns. This catches a rollback, a switch without `steamos-etc`, or a SteamOS update resetting `/etc`.

## Options

| Option | What it does |
| --- | --- |
| `files` | Path relative to `/etc` -> content |
| `services` | System services, shaped like Home Manager's `systemd.user.services`. See [Services](#services). |
| `waitForNix` | Adds a `user@.service` drop-in that holds the user session until `nix.mount`. Without it, Home Manager's `environment.d` and `user-dirs.dirs` links can dangle at login. |
| `gpuDrivers` | Creates `/run/opengl-driver` at boot through a tmpfiles rule. This replaces `non-nixos-gpu-setup`, whose rule is itself a store link and so is unreadable at boot. Also silences Home Manager's hint to run that script. |

If you ran `non-nixos-gpu-setup` before, `steamos-etc` replaces its `/etc/tmpfiles.d/non-nixos-gpu.conf` link. Its gcroot, `/nix/var/nix/gcroots/non-nixos-gpu.conf`, then points at the new file and can be deleted.

## Services

`services` writes system units the way Home Manager's `systemd.user.services` writes user units:

```nix
programs.steamos-etc.services.tailscaled = {
  Unit.Description = "Tailscale node agent";
  Service = {
    ExecStart = "${pkgs.tailscale}/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state";
    Type = "notify";
    StateDirectory = "tailscale";
  };
  Install.WantedBy = [ "multi-user.target" ];
};
```

Two differences from writing the unit yourself:

- `RequiresMountsFor=/nix/store` is added, since system units start before `nix.mount`.
- `Install.WantedBy` and `Install.RequiredBy` become drop-ins on their targets (`multi-user.target.d/tailscaled.conf` with `Wants=tailscaled.service`). `systemctl enable` would make symlinks, which SteamOS updates drop. Other `Install` keys aren't supported.

Each unit and drop-in is an entry in `files`, so the keep list, gcroot and drift check cover them. A new service still needs `sudo systemctl start` once; after that its targets start it at boot, and `steamos-etc` restarts it when its unit changes.

## With steam-frame-nix

[steam-frame-nix](https://github.com/lhns/steam-frame-nix) writes nothing to `/etc`, so the two can be used together. Its template sets `targets.genericLinux.gpu.enable = false`. Turn that back on if you use `gpuDrivers`.

## Development

```bash
nix flake check
```

`checks/sync.nix` runs the command against a scratch root (`STEAMOS_ETC_ROOT`), which skips `sudo` and systemd.

TODO: a check that evaluates the module inside a Home Manager configuration.
