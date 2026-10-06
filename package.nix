{
  lib,
  linkFarm,
  writeText,
  writers,
  libcap,
  # Files to keep under /etc, relative path -> content, or { text | source, mode,
  # capabilities } (the module's fileType). Installed as real files rather than store
  # links: some are read at boot before /nix is mounted.
  files ? { },
}:
let
  manifest = "steamos-etc/manifest";
  keepList = "atomic-update.conf.d/steamos-etc.conf";

  # Text, or a file to copy, each with its mode and capabilities.
  normalize =
    file:
    {
      text = null;
      source = null;
      mode = "0644";
      capabilities = [ ];
    }
    // (if builtins.isString file then { text = file; } else file);

  # SteamOS updates drop /etc files missing from a keep list. This one covers
  # every managed file, the manifest and itself.
  allFiles = lib.mapAttrs (_: normalize) files // {
    ${keepList} = normalize (
      lib.concatMapStrings (path: "/etc/${path}\n") (
        builtins.attrNames files
        ++ [
          manifest
          keepList
        ]
      )
    );
  };

  tree = linkFarm "steamos-etc" (
    lib.mapAttrsToList (path: file: {
      name = path;
      path = if file.source != null then file.source else writeText (baseNameOf path) file.text;
    }) allFiles
  );

  # Only the files that declare more than the default mode.
  attributes = writeText "steamos-etc-attributes.json" (
    builtins.toJSON (
      lib.mapAttrs (_: file: { inherit (file) mode capabilities; }) (
        lib.filterAttrs (_: file: file.mode != "0644" || file.capabilities != [ ]) allFiles
      )
    )
  );
in
writers.writePython3Bin "steamos-etc" { flakeIgnore = [ "E501" ]; } (
  lib.replaceStrings
    [ "@tree@" "@manifest@" "@attributes@" "@getcap@" "@setcap@" ]
    [
      "${tree}"
      manifest
      "${attributes}"
      "${lib.getExe' libcap "getcap"}"
      "${lib.getExe' libcap "setcap"}"
    ]
    (builtins.readFile ./steamos_etc.py)
)
