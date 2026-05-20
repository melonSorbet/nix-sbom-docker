#!/usr/bin/env bash

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
APP="${1:-python-app}"
OUT="$ROOT/sbom-nix/$APP"
IMAGE_NAME="$APP-nix:latest"

mkdir -p "$OUT"
cd "$ROOT"

echo "==> Building Nix OCI image (.#$APP-image)"
nix build ".#$APP-image" -o "./result-$APP-image"

echo "==> sbomnix (runtime closure of .#$APP-env)"
sbomnix ".#$APP-env" \
  --csv="$OUT/sbomnix-runtime.csv" \
  --cdx="$OUT/sbomnix-runtime.cdx.json" \
  --spdx="$OUT/sbomnix-runtime.spdx.json"

echo "==> sbomnix (buildtime closure of .#$APP-env)"
sbomnix ".#$APP-env" --buildtime \
  --csv="$OUT/sbomnix-buildtime.csv" \
  --cdx="$OUT/sbomnix-buildtime.cdx.json" \
  --spdx="$OUT/sbomnix-buildtime.spdx.json"

echo "==> Loading image into docker as $IMAGE_NAME"
docker load < "./result-$APP-image"

echo "==> Syft on $IMAGE_NAME"
syft "$IMAGE_NAME" -o spdx-json="$OUT/syft.spdx.json" -o cyclonedx-json="$OUT/syft.cdx.json"

echo "==> Trivy on $IMAGE_NAME"
trivy image --quiet --format spdx-json --output "$OUT/trivy.spdx.json" "$IMAGE_NAME"
trivy image --quiet --format cyclonedx --output "$OUT/trivy.cdx.json" "$IMAGE_NAME"

echo
echo "Done. SBOMs in $OUT"
