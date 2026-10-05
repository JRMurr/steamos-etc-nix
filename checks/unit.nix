# Property tests for steamos_etc.py's pure functions.
{ pkgs }:
pkgs.runCommand "steamos-etc-unit"
  {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (ps: [
        ps.pytest
        ps.hypothesis
      ]))
    ];
  }
  ''
    cp ${../steamos_etc.py} steamos_etc.py
    cp ${../test_steamos_etc.py} test_steamos_etc.py
    pytest -q -p no:cacheprovider test_steamos_etc.py
    touch $out
  ''
