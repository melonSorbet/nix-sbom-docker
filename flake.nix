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

          # The Node app, built with buildNpmPackage. npmDepsHash is a
          # content hash over the entire resolved dependency tree — Nix
          # refuses to build if the fetched packages don't match it.
          nodeApp = pkgs.buildNpmPackage {
            pname = "node-app";
            version = "1.0.0";
            src = ./images/projects-to-build/node-app;
            npmDepsHash = "sha256-3Jue3Yl8VgyJqNX7kmU7fvIYm4HewDitnb1VcsbbBEc=";
            # Plain server — nothing to compile.
            dontNpmBuild = true;
            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib/node-app
              cp app.js $out/lib/node-app/
              cp -r node_modules $out/lib/node-app/
              runHook postInstall
            '';
          };
        in
        {
          ## im gonna move these to seperate files later on.
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

          # The Nix-built OCI image of the Node app, whose Dockerfile
          # baseline lives under images/projects-to-build/node-app.
          node-app-image = pkgs.dockerTools.buildLayeredImage {
            name = "node-app-nix";
            tag = "latest";
            contents = [
              pkgs.nodejs
              nodeApp
            ];
            config = {
              Cmd = [
                "${pkgs.nodejs}/bin/node"
                "${nodeApp}/lib/node-app/app.js"
              ];
              WorkingDir = "${nodeApp}/lib/node-app";
              ExposedPorts."8000/tcp" = { };
            };
          };

          # Flat env for sbomnix to scan — same closure as the image.
          node-app-env = pkgs.buildEnv {
            name = "node-app-env";
            paths = [
              pkgs.nodejs
              nodeApp
            ];
          };
        }
      );

      ## dev shells to use for fast development
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
              (python3.withPackages (
                ps: with ps; [
                  click
                  rich
                ]
              ))
            ];
          };
        }
      );
    };
}
