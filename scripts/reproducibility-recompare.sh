#!/usr/bin/env bash
# Re-compare two SBOM/PBOM sets from an existing reproducibility report dir,
# both strictly (bom-ref + everything) AND by content identity (PURL + output_path,
# ignoring the input-addressed .drv path).
#
# The content-identity check is the methodologically meaningful one: it tests
# whether the SBOM describes the same artifact, independent of how the BOM
# tool happened to identify each component (input-addressed .drv vs
# content-addressed output path).

set -euo pipefail

REPORT_DIR="${1:-}"
if [ -z "$REPORT_DIR" ] || [ ! -d "$REPORT_DIR" ]; then
  echo "usage: $0 <reports/reproducibility-TIMESTAMP>" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Two normalizers.
# ---------------------------------------------------------------------------
normalize_strict() {
  jq --sort-keys '
    .serialNumber = "<X>"
    | .metadata.timestamp = "<X>"
    | .components = ((.components // []) | sort_by(."bom-ref" // .name))
    | .dependencies = ((.dependencies // []) | map(.dependsOn = ((.dependsOn // []) | sort)) | sort_by(.ref))
  ' "$1"
}

# Content identity: components only, ignoring input-addressed identifiers
# (bom-ref, nix:drv_path). Keyed and sorted by PURL → output_path → name@version.
normalize_content() {
  jq --sort-keys '
    def content_key:
      .purl //
      ((.properties // [])[]? | select(.name == "nix:output_path") | .value) //
      ((.name // "?") + "@" + (.version // ""));
    def strip_input_addressed:
      del(."bom-ref")
      | if .properties
          then .properties = (.properties | map(select(.name != "nix:drv_path")))
          else .
        end;
    {
      bomFormat,
      specVersion,
      components: ((.components // []) | map(strip_input_addressed + {ck: content_key}) | sort_by(.ck) | map(del(.ck)))
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Discover apps present in this report dir.
# ---------------------------------------------------------------------------
apps=()
for f in "$REPORT_DIR"/*-sbomnix-runtime-1.cdx.json; do
  [ -e "$f" ] || continue
  base=$(basename "$f")
  app="${base%-sbomnix-runtime-1.cdx.json}"
  apps+=("$app")
done

if [ "${#apps[@]}" -eq 0 ]; then
  echo "no SBOM files found in $REPORT_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Compare and print table.
# ---------------------------------------------------------------------------
compare_pair() {
  local kind="$1" a="$2" b="$3" out_prefix="$4"
  local strict_a="$out_prefix-strict-1.json" strict_b="$out_prefix-strict-2.json"
  local content_a="$out_prefix-content-1.json" content_b="$out_prefix-content-2.json"
  normalize_strict  "$a" > "$strict_a"
  normalize_strict  "$b" > "$strict_b"
  normalize_content "$a" > "$content_a"
  normalize_content "$b" > "$content_b"
  diff -q "$strict_a"  "$strict_b"  >/dev/null && local s=PASS || local s=FAIL
  diff -q "$content_a" "$content_b" >/dev/null && local c=PASS || local c=FAIL
  echo "$s|$c"
}

{
  echo "REPRODUCIBILITY RE-COMPARE"
  echo "=========================="
  echo "Report : $REPORT_DIR"
  echo "Run    : $(date -Iseconds)"
  echo
  echo "Strict  = diff after normalizing serialNumber + timestamp + sort"
  echo "Content = diff ignoring input-addressed identifiers (.drv path),"
  echo "          components keyed by PURL > output_path > name@version"
  echo
  printf "%-12s | %-8s | %-8s | %-8s | %-8s | %-8s | %-8s\n" \
    "app" "rt-strict" "rt-content" "bt-strict" "bt-content" "pb-strict" "pb-content"
  echo "-------------|----------|----------|----------|----------|----------|----------"
  for app in "${apps[@]}"; do
    RT1="$REPORT_DIR/$app-sbomnix-runtime-1.cdx.json"
    RT2="$REPORT_DIR/$app-sbomnix-runtime-2.cdx.json"
    BT1="$REPORT_DIR/$app-sbomnix-buildtime-1.cdx.json"
    BT2="$REPORT_DIR/$app-sbomnix-buildtime-2.cdx.json"
    PB1="$REPORT_DIR/$app-pbom-1.cdx.json"
    PB2="$REPORT_DIR/$app-pbom-2.cdx.json"
    # Only compare what's present (node-app may still be running).
    if [ ! -e "$RT2" ]; then
      printf "%-12s | %-8s | %-8s | %-8s | %-8s | %-8s | %-8s\n" \
        "$app" "-" "-" "-" "-" "-" "-" "  (build 2 not yet complete)"
      continue
    fi
    rt_res=$(compare_pair rt "$RT1" "$RT2" "$REPORT_DIR/$app-rt")
    bt_res=$(compare_pair bt "$BT1" "$BT2" "$REPORT_DIR/$app-bt")
    pb_res=$(compare_pair pb "$PB1" "$PB2" "$REPORT_DIR/$app-pb")
    IFS='|' read -r rt_s rt_c <<< "$rt_res"
    IFS='|' read -r bt_s bt_c <<< "$bt_res"
    IFS='|' read -r pb_s pb_c <<< "$pb_res"
    printf "%-12s | %-8s | %-8s | %-8s | %-8s | %-8s | %-8s\n" \
      "$app" "$rt_s" "$rt_c" "$bt_s" "$bt_c" "$pb_s" "$pb_c"
  done
  echo
} | tee "$REPORT_DIR/RECOMPARE.txt"
