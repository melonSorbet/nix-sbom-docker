#!/usr/bin/env bash
# Build the Nix-based python-app image, generate sbomnix SBOMs from the derivation,
# then load the image into docker and run Syft + Trivy on it for comparison.
# Outputs land in sbom-nix/python-app/.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
OUT="$ROOT/sbom-nix/python-app"
IMAGE_NAME="python-app-nix:latest"

mkdir -p "$OUT"
cd "$ROOT"

echo "==> Building Nix OCI image (.#python-app-image)"
nix build .#python-app-image -o ./result-python-app-image

echo "==> sbomnix (runtime closure of .#python-app-env)"
sbomnix .#python-app-env \
  --csv="$OUT/sbomnix-runtime.csv" \
  --cdx="$OUT/sbomnix-runtime.cdx.json" \
  --spdx="$OUT/sbomnix-runtime.spdx.json"

echo "==> sbomnix (buildtime closure of .#python-app-env)"
sbomnix .#python-app-env --buildtime \
  --csv="$OUT/sbomnix-buildtime.csv" \
  --cdx="$OUT/sbomnix-buildtime.cdx.json" \
  --spdx="$OUT/sbomnix-buildtime.spdx.json"

echo "==> Loading image into docker as $IMAGE_NAME"
docker load < ./result-python-app-image

echo "==> Syft on $IMAGE_NAME"
syft "$IMAGE_NAME" -o spdx-json="$OUT/syft.spdx.json" -o cyclonedx-json="$OUT/syft.cdx.json"

echo "==> Trivy on $IMAGE_NAME"
trivy image --quiet --format spdx-json --output "$OUT/trivy.spdx.json" "$IMAGE_NAME"
trivy image --quiet --format cyclonedx --output "$OUT/trivy.cdx.json" "$IMAGE_NAME"

echo
echo "Done. SBOMs in $OUT"
