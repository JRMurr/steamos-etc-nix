{
  lib,
  linkFarm,
  writeText,
  writers,
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
writers.writePython3Bin "steamos-etc" { flakeIgnore = [ "E501" ]; } (
  lib.replaceStrings [ "@tree@" "@manifest@" ] [ "${tree}" manifest ] (
    builtins.readFile ./steamos_etc.py
  )
)
