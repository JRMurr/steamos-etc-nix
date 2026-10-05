{
  lib,
  linkFarm,
  writeText,
  writeShellApplication,
  coreutils,
  diffutils,
  findutils,
  # Files to keep under /etc, relative path -> content. Installed as real files
  # rather than store links: some are read at boot before /nix is mounted.
  files ? { },
}:
let
  manifest = "steamos-etc/manifest";
  keepList = "atomic-update.conf.d/steamos-etc.conf";

  # SteamOS updates drop /etc files missing from a keep list. This one covers
  # every managed file, the manifest and itself.
  allFiles = files // {
    ${keepList} = lib.concatMapStrings (path: "/etc/${path}\n") (
      builtins.attrNames files
      ++ [
        manifest
        keepList
      ]
    );
  };

  tree = linkFarm "steamos-etc" (
    lib.mapAttrsToList (path: text: {
      name = path;
      path = writeText (baseNameOf path) text;
    }) allFiles
  );
in
writeShellApplication {
  name = "steamos-etc";
  runtimeInputs = [
    coreutils
    diffutils
    findutils
  ];
  text = ''
    # STEAMOS_ETC_ROOT points /etc somewhere else, for tests: no sudo, no systemd.
    root="''${STEAMOS_ETC_ROOT:-/}"
    etc_dir="$root/etc"
    manifest="$etc_dir/${manifest}"
    tree=${tree}

    usage() {
      cat <<'USAGE'
    usage: steamos-etc [--check]

      (none)   install the declared /etc files, remove ones no longer declared
      --check  only report drift; exits 1 if there is any
    USAGE
    }

    managed_files() {
      find -L "$tree" -type f -printf '%P\n' | sort
    }

    stale_files() {
      [[ -f "$manifest" ]] || return 0
      comm -23 <(sort "$manifest") <(managed_files)
    }

    # A symlink counts as drift even with the right content: its target may not
    # be mounted yet when the file is needed.
    is_current() {
      local path=$1
      [[ ! -L "$etc_dir/$path" ]] && cmp -s "$tree/$path" "$etc_dir/$path"
    }

    # The service a unit file or drop-in belongs to, if it's one we may restart.
    # Templates are left alone: user@.service is the whole user session.
    service_of() {
      local unit
      case "$1" in
        systemd/system/*.service.d/*) unit=$(basename "$(dirname "$1")" .d) ;;
        systemd/system/*.service) unit=$(basename "$1") ;;
        *) return 1 ;;
      esac
      [[ "$unit" == *@.service ]] && return 1
      echo "$unit"
    }

    # The target a drop-in extends, for drop-ins on targets.
    target_of() {
      case "$1" in
        systemd/system/*.target.d/*) basename "$(dirname "$1")" .d ;;
        *) return 1 ;;
      esac
    }

    # The units a drop-in pulls in (Wants=, Requires=), templates excluded.
    wanted_by() {
      local unit
      # One line can name several units: Wants=a.service b.service
      sed -n 's/^\(Wants\|Requires\)=//p' "$1" | tr ' ' '\n' | while read -r unit; do
        [[ -z "$unit" || "$unit" == *@.* ]] || echo "$unit"
      done
    }

    # Whether a target is up, so what it pulls in should run now. Without systemd
    # (STEAMOS_ETC_ROOT), every target counts as up.
    target_active() {
      [[ "$root" == / ]] || return 0
      systemctl is-active --quiet "$1"
    }

    # Runs a systemctl action on a unit; with STEAMOS_ETC_ROOT, only prints it.
    unit_action() {
      echo "$1 $2"
      [[ "$root" == / ]] || return 0
      systemctl "$1" "$2"
    }

    check() {
      local drift=0 path

      while read -r path; do
        is_current "$path" && continue
        echo "differs: /etc/$path"
        drift=1
      done < <(managed_files)

      while read -r path; do
        echo "stale: /etc/$path"
        drift=1
      done < <(stale_files)

      return "$drift"
    }

    apply() {
      if check >/dev/null; then
        echo "/etc up to date"
        return 0
      fi

      if [[ "$root" == / && $EUID -ne 0 ]]; then
        exec sudo "$(readlink -f "$0")"
      fi

      local path unit target
      local -a tmpfiles=() targets=()
      local -A changed=() wanted=()

      while read -r path; do
        is_current "$path" && continue

        # rm first: install would write through a symlink into the store.
        rm -f "$etc_dir/$path"
        install -D -m 0644 "$tree/$path" "$etc_dir/$path"
        echo "installed /etc/$path"
        [[ "$path" == tmpfiles.d/* ]] && tmpfiles+=("$etc_dir/$path")
        if unit=$(service_of "$path"); then
          changed[$unit]=1
        fi
        if target=$(target_of "$path"); then
          targets+=("$target" "$path")
        fi
      done < <(managed_files)

      while read -r path; do
        # Stopped while its unit file still exists. A removed drop-in only
        # changes its service, which stays.
        if [[ "$path" == *.service ]] && unit=$(service_of "$path"); then
          unit_action stop "$unit"
          unset 'changed[$unit]'
        elif unit=$(service_of "$path"); then
          changed[$unit]=1
        fi
        rm -f "$etc_dir/$path"
        echo "removed /etc/$path"
      done < <(stale_files)

      mkdir -p "$(dirname "$manifest")"
      managed_files > "$manifest"

      if [[ "$root" == / ]]; then
        systemctl daemon-reload
      fi

      # What a new or changed target drop-in pulls in starts now, as it would at
      # boot, if that target is up.
      for ((i = 0; i < ''${#targets[@]}; i += 2)); do
        target_active "''${targets[i]}" || continue
        while read -r unit; do
          wanted[$unit]=1
        done < <(wanted_by "$etc_dir/''${targets[i + 1]}")
      done

      # Changed services: running ones pick up the new unit (try-restart); stopped
      # ones stay stopped unless a target wants them (restart starts them too).
      for unit in "''${!changed[@]}"; do
        [[ -v "wanted[$unit]" ]] && continue
        unit_action try-restart "$unit"
      done
      for unit in "''${!wanted[@]}"; do
        if [[ -v "changed[$unit]" ]]; then
          unit_action restart "$unit"
        else
          unit_action start "$unit"
        fi
      done

      [[ "$root" == / ]] || return 0

      # Root the tree: the files reference store paths (GPU drivers) that must
      # outlive the Home Manager generation that built them.
      ln -sfn "$tree" /nix/var/nix/gcroots/steamos-etc
      if [[ ''${#tmpfiles[@]} -gt 0 ]]; then
        systemd-tmpfiles --create "''${tmpfiles[@]}"
      fi
    }

    case "''${1:-}" in
      --check) check ;;
      "") apply ;;
      -h | --help) usage ;;
      *) usage >&2; exit 2 ;;
    esac
  '';
}
