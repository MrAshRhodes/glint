#!/usr/bin/env bash
# Permission-free CPU drawing comparison, not an input/presentation latency test.
set -euo pipefail
cd "$(dirname "$0")/.."

variant="${1:-}"
if [[ "$variant" != baseline && "$variant" != current ]] || (($# > 2)); then
  echo "Usage: Scripts/benchmark-overlay.sh baseline [git-revision] | current" >&2
  exit 2
fi
if [[ "$variant" == current && $# != 1 ]]; then
  echo "A git revision is only accepted for baseline." >&2
  exit 2
fi

rounds="${ROUNDS:-20}"
frames="${FRAMES:-120}"
draw_mode="${DRAW_MODE:-full}"
if [[ ! "$rounds" =~ ^[1-9][0-9]?$ || ! "$frames" =~ ^[1-9][0-9]{0,3}$ ]] ||
   ((rounds < 1 || rounds > 30 || frames < 1 || frames > 1000)); then
  echo "ROUNDS must be 1..30 and FRAMES must be 1..1000." >&2
  exit 2
fi
if [[ "$draw_mode" != full && "$draw_mode" != damage ]]; then
  echo "DRAW_MODE must be full or damage." >&2
  exit 2
fi

revision="$(git rev-parse --verify "${2:-HEAD}^{commit}")"
run=".build/benchmark/${variant}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$run/source" "$run/module-cache" "$run/compiler-tmp"
# Keep compiler intermediates inside this worktree, too.
export TMPDIR="$PWD/$run/compiler-tmp"
sources=()
for name in CaptureTypes SelectionOverlay WindowEnumerator OverlayPerformance; do
  path="Sources/GlintCapture/$name.swift"
  if [[ "$variant" == baseline ]]; then
    if ! git cat-file -e "$revision:$path" 2>/dev/null; then
      if [[ "$name" == OverlayPerformance ]]; then continue; fi
      echo "Missing baseline source: $path" >&2
      exit 1
    fi
    git show "$revision:$path" > "$run/source/$name.swift"
  else
    if [[ ! -f "$path" && "$name" == OverlayPerformance ]]; then continue; fi
    cp "$path" "$run/source/$name.swift"
  fi
  sources+=("$run/source/$name.swift")
done
cp Scripts/OverlayDrawingBenchmark.swift "$run/source/OverlayDrawingBenchmark.swift"
sources+=("$run/source/OverlayDrawingBenchmark.swift")
flags=()
damage_api=absent
if grep -Eq 'func refresh\(\).*-> *\[NSRect\]' "$run/source/SelectionOverlay.swift"; then
  flags+=(-D OVERLAY_DAMAGE_TRACKING)
  damage_api=present
fi
{
  printf 'variant=%s\nrevision=%s\ndraw_mode=%s\nrounds=%s\nwarm_frames_per_process=%s\n' \
    "$variant" "$revision" "$draw_mode" "$rounds" "$frames"
  printf 'measurement=offscreen synchronous CPU update/draw only; presentation and real events excluded\n'
  printf 'compiler=swiftc -O -parse-as-library\n'
  printf 'damage_api=%s\n' "$damage_api"
  swiftc --version
  sw_vers
  sysctl -n hw.model machdep.cpu.brand_string hw.memsize
  printf '\nsource SHA-256:\n'
  shasum -a 256 "${sources[@]}"
} > "$run/manifest.txt"
chmod a-w "${sources[@]}"

swiftc -O -parse-as-library -module-cache-path "$run/module-cache" \
  ${flags[@]+"${flags[@]}"} "${sources[@]}" -o "$run/overlay-benchmark"
: > "$run/samples.jsonl"
for ((round = 1; round <= rounds; round++)); do
  for scenario in area-cursor area-selection window-hover; do
    "$run/overlay-benchmark" "$scenario" "$frames" "$round" "$draw_mode" >> "$run/samples.jsonl"
  done
done
"$run/overlay-benchmark" --summarize "$run/samples.jsonl" > "$run/summary.json"
rm -rf "$run/module-cache" "$run/compiler-tmp"
printf 'Offscreen CPU benchmark artifacts: %s\n' "$run"
cat "$run/summary.json"
