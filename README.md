# steamos-etc-nix

Declarative `/etc` files and system services for standalone Home Manager on SteamOS (Steam Deck, Steam Frame).

Home Manager can't touch `/etc`, and on SteamOS the usual workarounds break. So this flake gives you a Home Manager module where you declare the `/etc` files (and systemd services) you want, plus a `steamos-etc` command that installs them. Run it after `home-manager switch`, it only asks for `sudo` when something actually changed.

It started as a way to get GPU drivers and [tailscale](#services) working on the Steam Frame. There's a write up of the full setup in [this blog post](https://johns.codes/blog/nix-on-steam-frame).

## Why not just write to /etc?

SteamOS has two quirks that break the normal approaches:

- **Updates replace the root.** `/etc` is a writable overlay (kept under `/var`), but an update drops any file that isn't on a keep list in `/etc/atomic-update.conf.d/`.
- **`/nix` mounts late.** The nix installer's `steam-deck` mode keeps the store in `/home/nix` and bind mounts it with `nix.mount`. tmpfiles and your user session start *before* that mount, so any store symlink they read is dangling.

So `steamos-etc`:

- installs real files, never store links (and replaces any link already in the way)
- adds every file it manages to `/etc/atomic-update.conf.d/steamos-etc.conf` so updates keep them
- removes files you stop declaring (tracked in `/etc/steamos-etc/manifest`)
- adds a gcroot (`/nix/var/nix/gcroots/steamos-etc`) so store paths the files mention don't get garbage collected
- reloads systemd and applies changed tmpfiles rules
- starts, restarts, and stops services as their units change (see [Services](#services))

## Usage

Add the flake input

```nix
# flake.nix
inputs.steamos-etc.url = "github:JRMurr/steamos-etc-nix";
```

then import the module and turn on what you need

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

    # any other file you want under /etc
    files."tmpfiles.d/my-cache.conf" = "d /var/cache/my-app 0755 root root -";
  };
}
```

Then switch and sync

```bash
home-manager switch --flake ~/nix-config && steamos-etc
```

`steamos-etc --check` shows what differs without changing anything (exits 1 if anything does). Home Manager activation runs the same check and warns you, since activation can't `sudo` itself. That catches a rollback, a switch where you forgot `steamos-etc`, or a SteamOS update resetting `/etc`.

## Options

| Option | What it does |
| --- | --- |
| `files` | Path relative to `/etc` -> content |
| `services` | System services, written like Home Manager's `systemd.user.services`. See [Services](#services). |
| `waitForNix` | Holds your user session until `nix.mount` is up (a `user@.service` drop-in). Without it Home Manager's `environment.d` and `user-dirs.dirs` links can dangle at login. |
| `gpuDrivers` | Sets up `/run/opengl-driver` at boot with a tmpfiles rule. Replaces `non-nixos-gpu-setup`, whose rule is itself a store link and so can't be read at boot. Also silences Home Manager telling you to run that script. |

If you already ran `non-nixos-gpu-setup`, `steamos-etc` replaces its `/etc/tmpfiles.d/non-nixos-gpu.conf` link. You can then delete its leftover gcroot at `/nix/var/nix/gcroots/non-nixos-gpu.conf`.

## Services

`services` lets you write system units the same way you'd write user units with `systemd.user.services`. For example here's tailscale

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

A couple things are different from writing the unit by hand:

- `RequiresMountsFor=/nix/store` gets added for you, since system units also start before `nix.mount`.
- `Install.WantedBy` and `Install.RequiredBy` turn into drop-ins on their targets (`multi-user.target.d/tailscaled.conf` with `Wants=tailscaled.service`). `systemctl enable` would make symlinks, which SteamOS updates throw away. Other `Install` keys aren't supported.

On each run `steamos-etc` also keeps the services in sync:

- a new service with `Install.WantedBy` starts right away (and on every boot after)
- a running service whose unit or `.service.d` drop-in changed gets restarted
- a service you removed gets stopped
- a service without `Install` is only installed, start it yourself
- template units (`user@.service`) are never restarted, that would kill your session

Each unit and drop-in is just an entry in `files` under the hood, so the keep list, gcroot and drift check all cover them.

## Development

```bash
nix flake check
```

The command itself is `steamos_etc.py`. The checks:

- `checks/sync.nix` runs it against a scratch root (`STEAMOS_ETC_ROOT`), which skips `sudo` and prints systemd actions instead of running them
- `checks/unit.nix` runs the Hypothesis property tests: `test_steamos_etc.py` for the pure functions, `test_apply.py` for `check`/`apply` over random sequences of generations
- `checks/activation.nix` and `checks/services.nix` evaluate the module inside a Home Manager config

CI (`.github/workflows/check.yml`) runs `nix flake check` on PRs and pushes to main, natively on both aarch64 (Steam Frame) and x86_64 (Steam Deck).
