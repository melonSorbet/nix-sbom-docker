with import <nixpkgs> { };

stdenv.mkDerivation {
  name = "vuln-test";

  buildInputs = [
    nodejs
  ];

  src = ./.;

  buildPhase = ''
    mkdir -p $out
    npm init -y
    npm install lodash@4.17.19
  '';
}
