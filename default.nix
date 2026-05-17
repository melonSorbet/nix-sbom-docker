{
  pkgs ? import <nixpkgs> { },
}:

pkgs.buildEnv {
  name = "image-root";
  paths = [
    pkgs.pkgs.bash
    pkgs.coreutils
  ];
}
