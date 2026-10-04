# steamos-etc

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
- reloads systemd and applies changed tmpfiles rules.

## Usage

```nix
# flake.nix
inputs.steamos-etc.url = "github:JRMurr/steamos-etc";
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

## Options

| Option | What it does |
| --- | --- |
| `files` | Path relative to `/etc` -> content |
| `waitForNix` | Adds a `user@.service` drop-in that holds the user session until `nix.mount`. Without it, Home Manager's `environment.d` and `user-dirs.dirs` links can dangle at login. |
| `gpuDrivers` | Creates `/run/opengl-driver` at boot through a tmpfiles rule. This replaces `non-nixos-gpu-setup`, whose rule is itself a store link and so is unreadable at boot. Also silences Home Manager's hint to run that script. |

If you ran `non-nixos-gpu-setup` before, `steamos-etc` replaces its `/etc/tmpfiles.d/non-nixos-gpu.conf` link. Its gcroot, `/nix/var/nix/gcroots/non-nixos-gpu.conf`, then points at the new file and can be deleted.

## With steam-frame-nix

[steam-frame-nix](https://github.com/lhns/steam-frame-nix) writes nothing to `/etc`, so the two can be used together. Its template sets `targets.genericLinux.gpu.enable = false`. Turn that back on if you use `gpuDrivers`.

## Development

```bash
nix flake check
```

`checks/sync.nix` runs the command against a scratch root (`STEAMOS_ETC_ROOT`), which skips `sudo` and systemd.

TODO: a check that evaluates the module inside a Home Manager configuration.
