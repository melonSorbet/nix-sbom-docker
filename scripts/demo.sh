#!/usr/bin/env bash
# End-to-end demo of the thesis: from the problem (untrustworthy SBOMs) to
# the contribution (reproducible builds + content-addressed PBOMs). Uses
# already-generated artifacts so the demo runs in seconds, not minutes.
# Pause between sections so the presenter can talk.

set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# ---------- styling ----------
BOLD=$'\033[1m'; DIM=$'\033[2m'
CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
RED=$'\033[31m'; MAGENTA=$'\033[35m'; BLUE=$'\033[34m'; RESET=$'\033[0m'

bar()    { printf "${CYAN}════════════════════════════════════════════════════════════════════════${RESET}\n"; }
header() { echo; bar; printf "  ${BOLD}%s${RESET}\n" "$1"; bar; echo; }
sub()    { echo; printf "${BOLD}${YELLOW}── %s ──${RESET}\n" "$1"; echo; }
say()    { printf "  %s\n" "$1"; }
dim()    { printf "  ${DIM}%s${RESET}\n" "$1"; }
quote()  { echo; printf "  ${MAGENTA}► %s${RESET}\n" "$1"; }
pause()  { echo; read -rsp "${DIM}  [press ENTER]${RESET}" _; echo; echo; }

count() { jq '.components | length' "$1" 2>/dev/null || echo "?"; }

# Find the latest reproducibility report dirs for each app (if any).
find_latest_repro() {
  # Find the latest report dir where THIS app was the primary test
  # (i.e. its RESULTS.txt contains a result row for the app).
  local app="$1" d
  for d in $(ls -dt reports/reproducibility-* 2>/dev/null); do
    if [ -f "$d/RESULTS.txt" ] && grep -q "^$app " "$d/RESULTS.txt"; then
      echo "$d"; return 0
    fi
  done
}
repro_python=$(find_latest_repro python-app)
repro_node=$(find_latest_repro node-app)

# =========================================================================
# SECTION 1 — the question
# =========================================================================
header "1 · The question"
say "Thesis title:  ${BOLD}Trustworthy SBOMs through Reproducible Build Systems${RESET}"
say ""
say "An SBOM is supposed to tell you what's in your software so you can"
say "find vulnerabilities, track licenses, and detect supply-chain attacks."
say ""
say "Two questions this demo will answer with data:"
say "   ${YELLOW}1.${RESET} Are post-hoc SBOM scanners actually trustworthy?"
say "   ${YELLOW}2.${RESET} Can a reproducible build system do better?"
pause

# =========================================================================
# SECTION 2 — traditional Docker: scanner chaos
# =========================================================================
header "2 · Baseline: traditional Docker build, three scanners"
say "We built ${BOLD}python-app${RESET} and ${BOLD}node-app${RESET} with hand-written Dockerfiles."
say "Then scanned each image with the three most-cited SBOM scanners."
sub "Component count on the SAME image, by scanner"
printf "  %-12s | %8s | %8s | %8s | %s\n" "app" "syft" "trivy" "cdxgen" "spread"
echo  "  -------------|----------|----------|----------|------"
for app in python-app node-app; do
  s=$(count sbom-default/$app/syft.cdx.json)
  t=$(count sbom-default/$app/trivy.cdx.json)
  c=$(count sbom-default/$app/cdxgen.cdx.json)
  max=$(printf "%s\n" "$s" "$t" "$c" | sort -n | tail -1)
  min=$(printf "%s\n" "$s" "$t" "$c" | sort -n | head -1)
  spread=$(awk -v a="$max" -v b="$min" 'BEGIN{ if (b>0) printf "%.1fx", a/b; else print "?" }')
  printf "  %-12s | ${GREEN}%8s${RESET} | ${YELLOW}%8s${RESET} | ${BLUE}%8s${RESET} | ${BOLD}${RED}%s${RESET}\n" \
    "$app" "$s" "$t" "$c" "$spread"
done
quote "Same image. Three tools. ${BOLD}Up to 28× disagreement.${RESET}"
quote "If the tools can't agree on what's in the artifact, none of their SBOMs is trustworthy."
pause

# =========================================================================
# SECTION 3 — Nix build
# =========================================================================
header "3 · The alternative: a reproducible build (Nix)"
say "Instead of an imperative Dockerfile, we describe the build declaratively:"
say "   ${DIM}flake.nix${RESET}  →  ${DIM}dockerTools.buildLayeredImage${RESET}"
say ""
say "Every input is pinned by hash (compiler, libraries, env vars, sources)."
say "The output store path is a cryptographic hash of the inputs:"
echo
for app in python-app node-app; do
  p=$(nix path-info ".#$app-image" 2>/dev/null | head -1)
  printf "  ${DIM}%-12s${RESET}  %s\n" "$app:" "$p"
done
quote "Same inputs → same hash → anyone can re-derive it. No trust required."
pause

# =========================================================================
# SECTION 4 — ground truth from the build graph
# =========================================================================
header "4 · The SBOM ground truth: read it from the build graph"
say "Because every input is declared, we don't need to ${BOLD}guess${RESET} what's in the image."
say "We can read it ${BOLD}directly${RESET} from the build graph. Two tools do this:"
say "   ${BOLD}sbomnix${RESET}  — traverses the runtime closure"
say "   ${BOLD}bombon${RESET}   — independent implementation, same idea"
echo
sub "Ground-truth runtime closure (the components you actually need to run)"
printf "  %-12s | %-12s | %-12s\n" "app" "sbomnix" "bombon"
echo  "  -------------|--------------|-------------"
for app in python-app node-app; do
  s=$(count sbom-nix/$app/sbomnix-runtime.cdx.json)
  b=$(count sbom-nix/$app/bombon.cdx.json)
  printf "  %-12s | ${GREEN}%-12s${RESET} | ${GREEN}%-12s${RESET}\n" "$app" "$s" "$b"
done
quote "Two independent derivational tools, near-identical answers."
quote "${BOLD}This is your ground truth.${RESET}"
pause

# =========================================================================
# SECTION 5 — the headline finding
# =========================================================================
header "5 · Findings: scanners are inaccurate AND incomplete"
sub "Four-quadrant table (the comparison spine of the thesis)"
printf "  %-12s | %-25s | %-15s\n" "" "traditional Docker (scan)" "Nix image (scan)"
printf "  %-12s | %-25s | %-15s\n" "" "syft / trivy / cdxgen" "syft/trivy/cdxgen"
echo  "  -------------|---------------------------|----------------"
for app in python-app node-app; do
  s_t=$(count sbom-default/$app/syft.cdx.json)
  t_t=$(count sbom-default/$app/trivy.cdx.json)
  c_t=$(count sbom-default/$app/cdxgen.cdx.json)
  s_n=$(count sbom-nix/$app/syft.cdx.json)
  t_n=$(count sbom-nix/$app/trivy.cdx.json)
  c_n=$(count sbom-nix/$app/cdxgen.cdx.json)
  printf "  %-12s | %5s / %5s / %5s     | %4s / %4s / %4s\n" \
    "$app" "$s_t" "$t_t" "$c_t" "$s_n" "$t_n" "$c_n"
done
echo
sub "Ground truth (from build graph) for comparison"
printf "  %-12s | runtime: %-3s | buildtime: %-4s\n" "python-app" \
  "$(count sbom-nix/python-app/sbomnix-runtime.cdx.json)" \
  "$(count sbom-nix/python-app/sbomnix-buildtime.cdx.json)"
printf "  %-12s | runtime: %-3s | buildtime: %-4s\n" "node-app" \
  "$(count sbom-nix/node-app/sbomnix-runtime.cdx.json)" \
  "$(count sbom-nix/node-app/sbomnix-buildtime.cdx.json)"
echo
quote "${BOLD}${RED}Inversion finding:${RESET} truth says python(36) > node(20)."
quote "syft says node(565) ≫ python(83) — it ${BOLD}reverses the ranking${RESET}."
quote "trivy misses 67% of the true runtime closure (12/36). Replicates Kawaguchi."
pause

# =========================================================================
# SECTION 6 — the PBOM (our contribution)
# =========================================================================
header "6 · The PBOM: what BUILT the artifact, not what's IN it"
say "An SBOM tells you what the artifact contains."
say "A ${BOLD}PBOM${RESET} (Process Bill of Materials) tells you ${BOLD}how it was built${RESET}."
say ""
say "We built ${DIM}tools/pbom-emitter/${RESET}  →  emits CycloneDX 1.6 with formulation."
say ""
say "Live PBOM report for python-app:"
echo
python tools/pbom-emitter/pbom_summary.py sbom-nix/python-app/pbom.cdx.json --order 5 || true
echo
quote "1622 components touched the build. Image scanners see 36."
quote "${BOLD}The gap (1586 build-only inputs) is the supply-chain attack surface no scanner can see.${RESET}"
pause

# =========================================================================
# SECTION 7 — reproducibility
# =========================================================================
header "7 · Reproducibility — measured, not promised"
say "Cold-rebuild test: delete the result, garbage-collect, rebuild from scratch,"
say "compare hashes + SBOMs + PBOM."
sub "Per-app result (strict = bit-equal serialization; content = same artifact identity)"
print_recompare_rows() {
  local d="$1"
  [ -f "$d/RECOMPARE.txt" ] || return 0
  grep -E '^(python-app|node-app)\s' "$d/RECOMPARE.txt" \
    | sed -e "s/PASS/${GREEN}PASS${RESET}/g" -e "s/FAIL/${YELLOW}FAIL${RESET}/g" \
    | sed 's/^/  /'
}
printf "  %-12s | %-9s | %-10s | %-9s | %-10s | %-9s | %-10s\n" \
  "app" "rt-strict" "rt-content" "bt-strict" "bt-content" "pb-strict" "pb-content"
echo  "  -------------|-----------|------------|-----------|------------|-----------|-----------"
[ -n "${repro_python:-}" ] && print_recompare_rows "$repro_python"
[ -n "${repro_node:-}"   ] && print_recompare_rows "$repro_node"

sub "Why the one FAIL? (this is the most interesting result)"
say "${BOLD}python-app rt-strict FAIL${RESET}: 6 of 36 runtime components had different"
say "${BOLD}.drv${RESET}-path bom-refs across the cold rebuild. ${BOLD}But:${RESET}"
say "   ${GREEN}✓${RESET} same ${BOLD}PURL${RESET}             (pkg:nix/readline@8.3p1)"
say "   ${GREEN}✓${RESET} same ${BOLD}output store path${RESET} (/nix/store/brb97wgi…-readline-8.3p1)"
say "   ${GREEN}✓${RESET} same ${BOLD}binary bytes${RESET}      (tarball sha256 matches — see below)"
echo
say "This is Nix's ${BOLD}\"equivalent derivations\"${RESET} phenomenon: two .drv recipes"
say "can have different text but evaluate to the same output. sbomnix uses the"
say "input-addressed .drv path as ${BOLD}bom-ref${RESET}, so the SBOM inherits that instability."
echo
say "${BOLD}Implication:${RESET} a reproducible build does ${BOLD}not${RESET} automatically yield a"
say "reproducible SBOM — it depends on the SBOM tool's identifier choice."
say "Use ${BOLD}content-addressed${RESET} identifiers (PURL, output path), not input-addressed (.drv)."
say "Our PBOM emitter now does exactly this — that's why every PBOM column is PASS."
echo
quote "FAIL at the identifier level, PASS at the artifact level."
quote "${BOLD}This is a design recommendation for SBOM tooling, not a build problem.${RESET}"

sub "Tarball sha256 (build 1 vs build 2 after cold rebuild)"
for d in "${repro_python:-}" "${repro_node:-}"; do
  [ -z "$d" ] || [ ! -f "$d/RESULTS.txt" ] && continue
  awk '/^  [a-z].*:$/ {app=$1; next} /tarball sha \(build [12]\)/ {print "  "app, $0}' "$d/RESULTS.txt"
done
echo
quote "Both images are ${BOLD}byte-identical${RESET} across a cold rebuild that freed 17 GB of store."
quote "PBOM is byte-identical after we tag scope by content-identity (PURL),"
quote "not by sbomnix's input-addressed .drv-path. ${BOLD}That's a design recommendation.${RESET}"
pause

# =========================================================================
# SECTION 8 — wrap
# =========================================================================
header "8 · What this proves vs the exposé"
printf "  %-30s %s\n" "Exposé claim (§6)"                       "Status"
echo  "  -------------------------------|----------"
printf "  %-30s ${GREEN}backed${RESET}  (28× scanner disagreement, 67%% recall miss)\n" "Completeness gap"
printf "  %-30s ${GREEN}backed${RESET}  (ranking inversion on identical images)\n"    "Accuracy gap"
printf "  %-30s ${GREEN}backed${RESET}  (cold-rebuild bit-identical for both apps)\n" "Reproducibility"
printf "  %-30s ${GREEN}backed${RESET}  (sbomnix CDX+SPDX, bombon CDX, PBOM CDX)\n"   "SPDX+CycloneDX emission"
printf "  %-30s ${GREEN}backed${RESET}  (tools/oci-sbom; PBOM attach in progress)\n"  "Attach SBOM to image"
echo
quote "Open: PBOM-to-OCI attach polish + recall/precision per scanner + writing."
echo
bar
printf "  ${BOLD}Demo complete.${RESET}\n"
bar
echo
