#!/bin/zsh
# Opens and closes the app's browser many times in a simulator and checks that the app's memory
# does not grow with every page: what 100 opens leave must be within 1 MB of what 30 leave
# (in some runs the memory rises once over the first 25 or so opens; `PortsLoop` says more).
#
#   scripts/bench/ports-loop.sh <simulator id> [--opens N] [--bare] [--skip-build]
#
# Builds the benchmark's Release build (as scripts/bench/run.sh does, into the same folder),
# launches it with `-portsLoop N` (docs/debug-args.md) and waits for the result in the app's
# Documents/perf. The page is one the app serves to itself: no computer is needed, and the
# launch opens no pane (`-autoOpen zz-none -sizing mirror`). About 5 minutes for 100 opens.
# Exit status 1 when the memory grew by more than 1 MB or the run wrote no result. It also
# prints the last reading less the one after 5, so the early rise shows in every run; that
# number fails nothing. `--bare` opens a sheet with only a web view in place of the browser.
#
# Environment: BENCH_DD (derived data, default build/dd-bench).
set -euo pipefail

self=$0
usage() { sed -n '2,16p' "$self" | sed 's/^# \{0,1\}//'; exit 2; }
[[ $# -ge 1 ]] || usage
sim=$1; shift
opens=100; build=1; bare=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --opens) opens=$2; shift 2 ;;
    --bare) bare=(-portsLoopBare YES); shift ;;
    --skip-build) build=0; shift ;;
    *) usage ;;
  esac
done

here=${0:A:h}
root=${here:h:h}
bundle=dev.abrahamgonzalez.rexduo
dd=${BENCH_DD:-$root/build/dd-bench}

cleanup() { xcrun simctl terminate "$sim" $bundle >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

if (( build )); then
  echo "Building Release into $dd …" >&2
  mkdir -p "$root/build"
  (cd "$root" && xcodegen generate >/dev/null)
  # The same build as scripts/bench/run.sh makes: Release with the BENCH condition.
  xcodebuild -project "$root/Pteron.xcodeproj" -scheme Pteron -configuration Release \
    -destination "id=$sim" -derivedDataPath "$dd" -jobs 4 ONLY_ACTIVE_ARCH=YES \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BENCH' \
    build > "$root/build/ports-loop-build.log" 2>&1 \
    || { tail -30 "$root/build/ports-loop-build.log" >&2; exit 1; }
fi
app="$dd/Build/Products/Release-iphonesimulator/Pteron.app"
[[ -d $app ]] || { echo "no app at $app" >&2; exit 1; }

xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl terminate "$sim" $bundle >/dev/null 2>&1 || true
xcrun simctl install "$sim" "$app"
data=$(xcrun simctl get_app_container "$sim" $bundle data)
file="$data/Documents/perf/portsLoop.json"
rm -f "$file"
xcrun simctl launch "$sim" $bundle -portsLoop $opens $bare -autoOpen zz-none -sizing mirror >/dev/null

# 8 s to start, about 2.5 s an open, and three settles of 6 s.
limit=$(( 40 + opens * 4 ))
waited=0
until [[ -f $file ]]; do
  sleep 1
  (( waited += 1 ))
  if (( waited > limit )); then
    echo "no result after $limit s" >&2
    exit 1
  fi
done
cat "$file"; echo
python3 - "$file" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("%d opens: %.2f MB after 5, %.2f MB after 30, %.2f MB after all" % (r["opens"], r["afterFiveMB"], r["afterThirtyMB"], r["afterAllMB"]))
print("growth from 30: %.2f MB (limit 1.00)" % r["growthMB"])
if r["opens"] > 5:
    print("from 5 to the last: %.2f MB (the early rise, not a limit)" % (r["afterAllMB"] - r["afterFiveMB"]))
sys.exit(0 if r["growthMB"] <= 1.0 else 1)
PY
