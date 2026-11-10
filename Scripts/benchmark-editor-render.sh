#!/usr/bin/env bash
# Permission-free CPU comparison of the editor's render path, not an input, frame-pacing or presentation test.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-}"
if [[ "$mode" != baseline && "$mode" != current && "$mode" != compare ]] || (($# > 2)); then
  echo "Usage: Scripts/benchmark-editor-render.sh baseline [git-revision] | current | compare [git-revision]" >&2
  exit 2
fi
if [[ "$mode" == current && $# != 1 ]]; then
  echo "A git revision is only accepted for baseline and compare." >&2
  exit 2
fi

rounds="${ROUNDS:-5}"
frames="${FRAMES:-24}"
size="${SIZE:-5120x2880}"
source_space="${SOURCE:-p3}"
if [[ ! "$rounds" =~ ^[1-9][0-9]?$ || ! "$frames" =~ ^[1-9][0-9]{0,2}$ ]] ||
   ((rounds < 1 || rounds > 30 || frames < 2 || frames > 500)); then
  echo "ROUNDS must be 1..30 and FRAMES must be 2..500." >&2
  exit 2
fi
if [[ ! "$size" =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]]; then
  echo "SIZE must look like 5120x2880 (pixels, 100..99999 each side)." >&2
  exit 2
fi
if [[ "$source_space" != p3 && "$source_space" != srgb ]]; then
  echo "SOURCE must be p3 or srgb." >&2
  exit 2
fi

revision="$(git rev-parse --verify "${2:-HEAD}^{commit}")"
run=".build/benchmark/editor-render-${mode}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$run/module-cache" "$run/compiler-tmp" "$run/assets"
# Keep compiler intermediates inside this worktree, too.
export TMPDIR="$PWD/$run/compiler-tmp"

# scenario annotation-count: the same matrix for every variant.
matrix=("padding-drag 0" "padding-drag 12" "padding-drag 40" "shadow-drag 12" "annotation-drag 12"
        "padding-drag-magnifier 12" "background-cycle 0" "export-after-preview 12" "stages 12")

# build <baseline|current> <directory>: GlintCore from the revision (or this worktree) plus the benchmark, one module.
build() {
  local variant="$1" dir="$2" path flags=()
  mkdir -p "$dir/source"
  if [[ "$variant" == baseline ]]; then
    while IFS= read -r path; do
      if [[ "$path" == *.swift ]]; then git show "$revision:$path" > "$dir/source/$(basename "$path")"; fi
    done < <(git ls-tree --name-only -r "$revision" Sources/GlintCore/)
  else
    cp Sources/GlintCore/*.swift "$dir/source/"
  fi
  if [[ ! -s "$dir/source/Compositor.swift" ]]; then
    echo "Missing GlintCore sources for $variant ($revision)." >&2
    exit 1
  fi
  cp Scripts/EditorRenderBenchmark.swift "$dir/source/EditorRenderBenchmark.swift"
  if grep -q 'final class RenderCache' "$dir"/source/*.swift; then flags+=(-D RENDER_CACHE); fi
  chmod a-w "$dir"/source/*.swift
  swiftc -O -wmo -swift-version 5 -suppress-warnings -parse-as-library -module-name EditorRenderBenchmark \
    -module-cache-path "$run/module-cache" ${flags[@]+"${flags[@]}"} "$dir"/source/*.swift \
    -o "$dir/editor-render-benchmark"
  {
    printf 'variant=%s\ncompiler=swiftc -O -wmo -swift-version 5 -suppress-warnings -parse-as-library\nrender_cache=%s\n' \
      "$variant" "$([[ ${#flags[@]} -gt 0 ]] && echo present || echo absent)"
    if [[ "$variant" == baseline ]]; then printf 'revision=%s\n' "$revision"; else printf 'revision=working tree on %s\n' "$(git rev-parse HEAD)"; fi
    printf 'source SHA-256:\n'
    shasum -a 256 "$dir"/source/*.swift
  } > "$dir/variant.txt"
}

# sample <directory> <round>: one fresh process per scenario so first-use cost and peak memory stay separate.
sample() {
  local dir="$1" round="$2" entry
  for entry in "${matrix[@]}"; do
    "$dir/editor-render-benchmark" "${entry% *}" "$round" "${entry#* }" "$source_space" "$size" "$frames" \
      "$run/assets" >> "$dir/samples.jsonl"
  done
}

variants=()
case "$mode" in
  baseline) variants=(baseline) ;;
  current) variants=(current) ;;
  compare) variants=(baseline current) ;;
esac
for variant in "${variants[@]}"; do
  mkdir -p "$run/$variant"
  build "$variant" "$run/$variant"
  : > "$run/$variant/samples.jsonl"
done

{
  printf 'mode=%s\nrounds=%s\nwarm_frames_per_process=%s (the first frame is reported separately)\n' \
    "$mode" "$rounds" "$frames"
  printf 'source=%s capture at %s pixels, backing scale 2, preview scale fitted to 1800 x 1200\n' "$source_space" "$size"
  printf 'scenarios=%s\n' "${matrix[*]}"
  printf 'measurement=offscreen CPU render time and peak memory of one process each; presentation, window system, and real events excluded\n'
  printf 'load before:'; sysctl -n vm.loadavg
  swiftc --version
  sw_vers
  sysctl -n hw.model machdep.cpu.brand_string hw.memsize
  for variant in "${variants[@]}"; do printf '\n[%s]\n' "$variant"; cat "$run/$variant/variant.txt"; done
} > "$run/manifest.txt"

for ((round = 1; round <= rounds; round++)); do
  order=("${variants[@]}")
  # Alternate which variant goes first so a drifting host load does not favour either.
  if ((${#variants[@]} == 2 && round % 2 == 0)); then order=(current baseline); fi
  for variant in "${order[@]}"; do sample "$run/$variant" "$round"; done
done
{ printf 'load after:'; sysctl -n vm.loadavg; } >> "$run/manifest.txt"

for variant in "${variants[@]}"; do
  "$run/$variant/editor-render-benchmark" --summarize "$run/$variant/samples.jsonl" > "$run/$variant/summary.json"
done
rm -rf "$run/module-cache" "$run/compiler-tmp"
printf 'Offscreen CPU benchmark artifacts: %s\n' "$run"
for variant in "${variants[@]}"; do
  printf '\n[%s]\n' "$variant"
  cat "$run/$variant/summary.json"
done
