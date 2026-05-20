{
  description = "Trustworthy SBOMs through Reproducible Build Systems — thesis prototype";

  inputs.nixpkgs.url = "nixpkgs/nixos-25.11";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};

          pythonEnv = pkgs.python3.withPackages (
            ps: with ps; [
              flask
              requests
              click
            ]
          );

          pythonAppSrc = pkgs.runCommand "python-app-src" { } ''
            mkdir -p $out/app
            cp ${./images/projects-to-build/python-app/app.py} $out/app/app.py
          '';
        in
        {
          # The thing we ship: a Nix-built OCI image of the same Python app
          # whose Dockerfile baseline lives under images/projects-to-build/python-app.
          python-app-image = pkgs.dockerTools.buildLayeredImage {
            name = "python-app-nix";
            tag = "latest";
            contents = [
              pythonEnv
              pythonAppSrc
            ];
            config = {
              Cmd = [
                "${pythonEnv}/bin/python"
                "/app/app.py"
              ];
              WorkingDir = "/app";
              ExposedPorts."8000/tcp" = { };
            };
          };

          # The same content set as a flat env. sbomnix scans this to produce
          # SBOMs whose closure exactly matches what's inside the image.
          python-app-env = pkgs.buildEnv {
            name = "python-app-env";
            paths = [
              pythonEnv
              pythonAppSrc
            ];
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              # Nix-side SBOM
              sbomnix
              # Post-hoc scanners we compare against
              syft
              trivy
              grype
              # Image plumbing
              skopeo
              jq
              # Attach tool runtime
              (python3.withPackages (ps: with ps; [ click rich ]))
            ];
          };
        }
      );
    };
}
