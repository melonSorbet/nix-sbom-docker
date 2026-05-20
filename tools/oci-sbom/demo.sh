#!/usr/bin/env bash
# demo.sh — one full run of oci-sbom:
#   build the Nix image -> convert to OCI layout -> attach SBOMs ->
#   list -> verify -> extract -> round-trip check.
set -euo pipefail

# Resolve paths relative to this script, so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# Re-exec inside the Nix dev shell if skopeo / python deps aren't on PATH yet.
if ! command -v skopeo >/dev/null 2>&1; then
  echo "==> entering nix dev shell"
  exec nix develop -c bash "$0" "$@"
fi

IMAGE_DIR="/tmp/oci-sbom-demo"
EXTRACTED="/tmp/oci-sbom-demo-extracted.cdx.json"
SBOM_CDX="sbom-nix/python-app/sbomnix-runtime.cdx.json"
SBOM_SPDX="sbom-nix/python-app/sbomnix-runtime.spdx.json"
TOOL=(python "$SCRIPT_DIR/oci_sbom.py")

echo "==> 1/6  build the Nix image"
nix build .#python-app-image

echo "==> 2/6  convert docker-archive -> OCI layout"
rm -rf "$IMAGE_DIR"
skopeo copy docker-archive:result "oci:$IMAGE_DIR:latest"

echo "==> 3/6  attach SBOMs (CycloneDX + SPDX)"
"${TOOL[@]}" attach -i "$IMAGE_DIR" -s "$SBOM_CDX"  -t application/vnd.cyclonedx+json
"${TOOL[@]}" attach -i "$IMAGE_DIR" -s "$SBOM_SPDX" -t application/spdx+json

echo "==> 4/6  list attachments"
"${TOOL[@]}" list -i "$IMAGE_DIR"

echo "==> 5/6  verify every digest"
"${TOOL[@]}" verify -i "$IMAGE_DIR"

echo "==> 6/6  extract + round-trip check"
"${TOOL[@]}" extract -i "$IMAGE_DIR" -k org.opencontainers.image.sbom.cyclonedx -o "$EXTRACTED"
if diff -q "$SBOM_CDX" "$EXTRACTED" >/dev/null; then
  echo "round-trip: BYTE-IDENTICAL"
else
  echo "round-trip: MISMATCH" >&2
  exit 1
fi

echo
echo "done. OCI layout with SBOMs attached: $IMAGE_DIR"
