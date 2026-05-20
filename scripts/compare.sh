#!/usr/bin/env bash

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
APP="${1:-python-app}"

count_cdx() {
  local f="$1"
  if [[ -f "$f" ]]; then
    jq '.components | length' "$f"
  else
    echo "missing"
  fi
}

printf "%-40s %10s\n" "SBOM" "components"
printf "%-40s %10s\n" "----" "----------"

printf "%-40s %10s\n" "nix:sbomnix (runtime)"  "$(count_cdx "$ROOT/sbom-nix/$APP/sbomnix-runtime.cdx.json")"
printf "%-40s %10s\n" "nix:sbomnix (buildtime)" "$(count_cdx "$ROOT/sbom-nix/$APP/sbomnix-buildtime.cdx.json")"
printf "%-40s %10s\n" "nix:syft"               "$(count_cdx "$ROOT/sbom-nix/$APP/syft.cdx.json")"
printf "%-40s %10s\n" "nix:trivy"              "$(count_cdx "$ROOT/sbom-nix/$APP/trivy.cdx.json")"
printf "%-40s %10s\n" "default:syft"           "$(count_cdx "$ROOT/sbom-default/$APP/syft.cdx.json")"
printf "%-40s %10s\n" "default:trivy"          "$(count_cdx "$ROOT/sbom-default/$APP/trivy.cdx.json")"
