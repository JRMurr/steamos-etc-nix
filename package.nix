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

      local path
      local -a tmpfiles=()

      while read -r path; do
        is_current "$path" && continue

        # rm first: install would write through a symlink into the store.
        rm -f "$etc_dir/$path"
        install -D -m 0644 "$tree/$path" "$etc_dir/$path"
        echo "installed /etc/$path"
        [[ "$path" == tmpfiles.d/* ]] && tmpfiles+=("$etc_dir/$path")
      done < <(managed_files)

      while read -r path; do
        rm -f "$etc_dir/$path"
        echo "removed /etc/$path"
      done < <(stale_files)

      mkdir -p "$(dirname "$manifest")"
      managed_files > "$manifest"

      [[ "$root" == / ]] || return 0

      # Root the tree: the files reference store paths (GPU drivers) that must
      # outlive the Home Manager generation that built them.
      ln -sfn "$tree" /nix/var/nix/gcroots/steamos-etc
      systemctl daemon-reload
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
