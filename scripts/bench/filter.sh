#!/bin/zsh
# Measures the stream's filter (APCFilter) against the one it replaced, on the Mac: no
# simulator, no server, about 20 s after the build. Exit status 1 when it is slower than the
# budget in scripts/bench/budgets.mjs (`filter.ratioToBefore`).
#
#   scripts/bench/filter.sh
#
# It is RexKit's StreamFilterBenchmarkTests.testCollectionOffIsAsFastAsBefore, which the unit
# suite skips: a measurement fails on a busy machine, so it runs here, by itself. Run it with
# the Mac otherwise idle, as the rest of the benchmark.
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
ratio=$(node -e "import('$here/budgets.mjs').then(b => console.log(b.filter.ratioToBefore))")
log=$(mktemp)
trap 'rm -f "$log"' EXIT
if PTERON_BENCH_FILTER_RATIO=$ratio swift test --package-path "$root/Packages/RexKit" \
    --filter 'StreamFilterBenchmarkTests/testCollectionOffIsAsFastAsBefore' >"$log" 2>&1; then
  grep -E 'APCFilter (throughput|ratio)' "$log"
  echo "filter: within the budget ($ratio)"
else
  grep -E 'APCFilter (throughput|ratio)| error: ' "$log" >&2 || tail -20 "$log" >&2
  echo "filter: over the budget ($ratio)" >&2
  exit 1
fi
