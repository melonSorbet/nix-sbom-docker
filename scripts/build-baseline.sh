#!/usr/bin/env bash

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
APP="${1:-python-app}"
APP_DIR="$ROOT/images/projects-to-build/$APP"
OUT="$ROOT/sbom-default/$APP"
IMAGE_NAME="$APP-default:latest"

mkdir -p "$OUT"

echo "==> docker build $IMAGE_NAME from $APP_DIR"
docker build -t "$IMAGE_NAME" "$APP_DIR"

echo "==> Syft on $IMAGE_NAME"
syft "$IMAGE_NAME" -o spdx-json="$OUT/syft.spdx.json" -o cyclonedx-json="$OUT/syft.cdx.json"

echo "==> Trivy on $IMAGE_NAME"
trivy image --quiet --format spdx-json --output "$OUT/trivy.spdx.json" "$IMAGE_NAME"
trivy image --quiet --format cyclonedx --output "$OUT/trivy.cdx.json" "$IMAGE_NAME"

echo "==> cdxgen on $IMAGE_NAME"
cdxgen -t docker -o "$OUT/cdxgen.cdx.json" "$IMAGE_NAME"

echo
echo "Done. SBOMs in $OUT"
