#!/bin/zsh
# Measures how long a pane's title and a waiting badge take to show while a program floods
# progress reports, in a simulator: no real server (the test brings its own). Exit status 1
# when either takes longer than the budget in scripts/bench/budgets.mjs (`flood.lagSeconds`).
#
#   scripts/bench/flood.sh <simulator id>
#
# It is the app test AlertEventsTests.testATitleShowsAtItsUsualPaceDuringAProgressFlood. The
# unit suite runs it without the limit: a measurement fails on a busy machine, so the limit is
# checked here, by itself, with the Mac otherwise idle.
#
# Environment: BENCH_TEST_DD (derived data, default build/dd-bench-tests).
set -euo pipefail
[[ $# -eq 1 ]] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
sim=$1
here=${0:A:h}
root=${here:h:h}
dd=${BENCH_TEST_DD:-$root/build/dd-bench-tests}
limit=$(node -e "import('$here/budgets.mjs').then(b => console.log(b.flood.lagSeconds))")
log=$(mktemp)
trap 'rm -f "$log"' EXIT
# `TEST_RUNNER_` hands the variable to the test's process in the simulator.
if TEST_RUNNER_REXDUO_BENCH_FLOOD_LAG=$limit xcodebuild -project "$root/RexDuo.xcodeproj" -scheme RexDuo \
    -destination "id=$sim" -derivedDataPath "$dd" test \
    -only-testing:RexDuoTests/AlertEventsTests/testATitleShowsAtItsUsualPaceDuringAProgressFlood >"$log" 2>&1; then
  grep -E 'FLOOD title lags' "$log" || true
  echo "flood: within the budget ($limit s)"
else
  grep -E 'FLOOD title lags| error: ' "$log" >&2 || tail -30 "$log" >&2
  echo "flood: over the budget ($limit s)" >&2
  exit 1
fi
