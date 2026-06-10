#!/usr/bin/env bash
# Reproducibility experiment: delete the build output, force a cold rebuild,
# and verify that we get the same store path, the same tarball bytes, and
# the same SBOMs/PBOMs back. Backs the §6 "Reproducibility guarantees" claim.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

# Self-enter nix develop if sbomnix isn't on PATH yet.
if ! command -v sbomnix >/dev/null 2>&1; then
  echo "==> sbomnix not on PATH — re-exec'ing under 'nix develop'"
  exec nix develop "$ROOT" --command "$0" "$@"
fi
TS="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="$ROOT/reports/reproducibility-$TS"
LOG="$REPORT_DIR/run.log"
mkdir -p "$REPORT_DIR"
cd "$ROOT"

APPS=("$@")
if [ "${#APPS[@]}" -eq 0 ]; then
  APPS=(python-app node-app)
fi

# ---------------------------------------------------------------------------
# Normalize a CycloneDX file so we can diff two runs ignoring fields that are
# *expected* to vary even for an identical input set (UUIDs, wall-clock time).
# Also sort components and dependencies so array order doesn't trip the diff.
# ---------------------------------------------------------------------------
normalize_cdx() {
  jq --sort-keys '
    .serialNumber = "<REDACTED>"
    | (.metadata.timestamp // empty) as $_ | .metadata.timestamp = "<REDACTED>"
    | .components = ((.components // []) | sort_by(."bom-ref" // .name))
    | .dependencies = ((.dependencies // []) | map(.dependsOn = ((.dependsOn // []) | sort)) | sort_by(.ref))
  ' "$1"
}

pass_fail() {
  if "$@" >/dev/null 2>&1; then echo PASS; else echo FAIL; fi
}

results=()

for app in "${APPS[@]}"; do
  echo "======================================================="
  echo "  REPRODUCIBILITY TEST: $app"
  echo "======================================================="

  # -------- BUILD 1 --------
  echo "==> [1/2] Building .#$app-image (first build)"
  nix build ".#$app-image" -o "$ROOT/result-$app-image" 2>&1 | tee -a "$LOG"
  store_path_1=$(readlink "$ROOT/result-$app-image")
  tar_sha_1=$(sha256sum "$store_path_1" | awk '{print $1}')
  echo "    store-path : $store_path_1"
  echo "    tarball sha: $tar_sha_1"

  echo "==> [1/2] Generating SBOMs + PBOM"
  RT1="$REPORT_DIR/$app-sbomnix-runtime-1.cdx.json"
  BT1="$REPORT_DIR/$app-sbomnix-buildtime-1.cdx.json"
  PB1="$REPORT_DIR/$app-pbom-1.cdx.json"
  sbomnix ".#$app-env" --cdx="$RT1" >>"$LOG" 2>&1
  sbomnix ".#$app-env" --buildtime --cdx="$BT1" >>"$LOG" 2>&1
  python "$ROOT/tools/pbom-emitter/pbom_emitter.py" ".#$app-env" \
    --runtime-cdx="$RT1" --buildtime-cdx="$BT1" -o "$PB1" >>"$LOG" 2>&1

  # -------- TEAR DOWN --------
  echo "==> Deleting result symlink + targeted GC"
  rm "$ROOT/result-$app-image"
  # Also remove other result-* that pin parts of the closure for THIS app.
  # We only kill the app under test's roots, not the other app's.
  rm -f "$ROOT/result-$app-bom"
  nix-collect-garbage 2>&1 | tee -a "$LOG" | tail -3

  if [ -e "$store_path_1" ]; then
    echo "    [warn] $store_path_1 still exists after GC (pinned by another root)"
    truly_cold="no"
  else
    echo "    [ok]   $store_path_1 deleted — rebuild will be cold"
    truly_cold="yes"
  fi

  # -------- BUILD 2 --------
  echo "==> [2/2] Rebuilding .#$app-image (cold)"
  nix build ".#$app-image" -o "$ROOT/result-$app-image" 2>&1 | tee -a "$LOG"
  store_path_2=$(readlink "$ROOT/result-$app-image")
  tar_sha_2=$(sha256sum "$store_path_2" | awk '{print $1}')
  echo "    store-path : $store_path_2"
  echo "    tarball sha: $tar_sha_2"

  echo "==> [2/2] Regenerating SBOMs + PBOM"
  RT2="$REPORT_DIR/$app-sbomnix-runtime-2.cdx.json"
  BT2="$REPORT_DIR/$app-sbomnix-buildtime-2.cdx.json"
  PB2="$REPORT_DIR/$app-pbom-2.cdx.json"
  sbomnix ".#$app-env" --cdx="$RT2" >>"$LOG" 2>&1
  sbomnix ".#$app-env" --buildtime --cdx="$BT2" >>"$LOG" 2>&1
  python "$ROOT/tools/pbom-emitter/pbom_emitter.py" ".#$app-env" \
    --runtime-cdx="$RT2" --buildtime-cdx="$BT2" -o "$PB2" >>"$LOG" 2>&1

  # -------- COMPARE --------
  echo "==> Comparing"
  storepath_result=$([ "$store_path_1" = "$store_path_2" ] && echo PASS || echo FAIL)
  tarball_result=$([ "$tar_sha_1" = "$tar_sha_2" ] && echo PASS || echo FAIL)

  for kind in rt bt pb; do
    case $kind in
      rt) A=$RT1 B=$RT2 ;;
      bt) A=$BT1 B=$BT2 ;;
      pb) A=$PB1 B=$PB2 ;;
    esac
    NA="$REPORT_DIR/$app-$kind-norm-1.json"
    NB="$REPORT_DIR/$app-$kind-norm-2.json"
    normalize_cdx "$A" > "$NA"
    normalize_cdx "$B" > "$NB"
    if diff -q "$NA" "$NB" >/dev/null; then
      eval "${kind}_result=PASS"
    else
      eval "${kind}_result=FAIL"
      diff "$NA" "$NB" > "$REPORT_DIR/$app-$kind-diff.txt" || true
    fi
  done

  results+=("$app|$truly_cold|$storepath_result|$tarball_result|$rt_result|$bt_result|$pb_result|$store_path_1|$tar_sha_1|$tar_sha_2")
  echo
done

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
{
  echo "REPRODUCIBILITY TEST REPORT"
  echo "==========================="
  echo "Run    : $(date -Iseconds)"
  echo "Host   : $(hostname)"
  echo "Nix    : $(nix --version)"
  echo "Method : delete result symlink + nix-collect-garbage between builds,"
  echo "         then rebuild and compare. SBOM/PBOM normalized for serialNumber,"
  echo "         metadata.timestamp, and component/dependency order."
  echo
  printf "%-12s | %-7s | %-10s | %-7s | %-7s | %-7s | %-4s\n" \
    "app" "cold?" "store-path" "tarball" "sbom-rt" "sbom-bt" "pbom"
  echo "-------------|---------|------------|---------|---------|---------|------"
  for r in "${results[@]}"; do
    IFS='|' read -r a cold sp tb rt bt pb sp_path sha1 sha2 <<< "$r"
    printf "%-12s | %-7s | %-10s | %-7s | %-7s | %-7s | %-4s\n" \
      "$a" "$cold" "$sp" "$tb" "$rt" "$bt" "$pb"
  done
  echo
  echo "Hashes:"
  for r in "${results[@]}"; do
    IFS='|' read -r a cold sp tb rt bt pb sp_path sha1 sha2 <<< "$r"
    echo "  $a:"
    echo "    store path  : $sp_path"
    echo "    tarball sha (build 1): $sha1"
    echo "    tarball sha (build 2): $sha2"
  done
  echo
  echo "Artifacts: $REPORT_DIR"
} | tee "$REPORT_DIR/RESULTS.txt"
