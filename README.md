# nix-sbom

Bachelor thesis prototype: **Trustworthy SBOMs through Reproducible Build Systems.**

The repo investigates how much more complete and trustworthy SBOMs become when
generated *from* the Nix build process versus *post-hoc* by container scanners
(Syft, Trivy). A Process Bill of Materials (PBOM) component is planned as a
second layer; its concrete schema is pending advisor clarification.

## Layout

```
flake.nix                              # exposes the Nix-built image + scan env
images/projects-to-build/<app>/        # source + Dockerfile (the baseline build)
images/flakes/<app>/                   # reserved for per-app standalone Nix flakes
sbom-default/<app>/                    # SBOMs from Syft + Trivy on the Dockerfile image
sbom-nix/<app>/                        # SBOMs from sbomnix + Syft + Trivy on the Nix image
scripts/                               # build + compare drivers
```

## First test subject: `python-app`

A minimal Flask app with three pip dependencies (`Flask`, `requests`, `click`).
Built two ways:

- **Baseline:** `images/projects-to-build/python-app/Dockerfile` — typical
  `python:3.12-slim-bookworm` + `pip install -r requirements.txt`.
- **Nix:** `flake.nix` exposes `packages.<system>.python-app-image`
  (`dockerTools.buildLayeredImage`) and `packages.<system>.python-app-env`
  (the same content set as a flat env, which is what `sbomnix` scans).

## Running the comparison

Enter the dev shell (which provides `sbomnix`, `syft`, `trivy`, `grype`,
`skopeo`, `jq`):

```bash
nix develop
```

Build the Dockerfile baseline and scan it:

```bash
./scripts/build-baseline.sh
# → sbom-default/python-app/{syft,trivy}.{spdx,cdx}.json
```

Build the Nix image and scan it (both via sbomnix and via Syft/Trivy):

```bash
./scripts/build-nix.sh
# → sbom-nix/python-app/{sbomnix-runtime,sbomnix-buildtime,syft,trivy}.*
```

Quick component-count diff:

```bash
./scripts/compare.sh python-app
```

## Status (as of 2026-05-17)

- [x] Test subject scaffolded (`python-app`, both build paths)
- [x] Nix image build verified — `nix build .#python-app-image` produces an
      OCI tarball; sbomnix on `.#python-app-env` returns 36 runtime components
- [ ] Run baseline + Nix scans end-to-end and capture first comparison numbers
- [ ] PBOM emitter (pending advisor clarification on schema/framework)
- [ ] OCI-referrer attachment of SBOMs (post-PBOM)
- [ ] Additional test subjects to widen the corpus
