#!/bin/zsh
# Runs the terminal engine benchmark in a simulator and prints the report.
#
#   scripts/bench/run.sh <simulator id> [--live <session label>] [--runs N] [--only a,b]
#                        [--out <dir>] [--skip-build]
#
# Builds the app once (Release), then for every scenario, engine and run launches it with
# `-replay <file> -perfLog <name>`, waits for the result file in the app's Documents/perf and
# copies it to <out>/results. Replay runs touch no server.
#
# --live <session label> also measures time to first frame on a real pane: 5 cold launches per
# engine with `-autoOpen <label> -sizing mirror`, after `seq 1 3000` in that session's pane.
# The app then connects to the local Rex server and opens that session, so the label must be a
# throwaway session of your own (`rex session new zz-…`). Mirror sizing never resizes the pane.
#
# Environment: BENCH_DD (derived data, default $TMPDIR/rex-bench-dd).
set -euo pipefail

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[[ $# -ge 1 ]] || usage
sim=$1; shift
live=""; runs=3; only=""; out=""; build=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --live) live=$2; shift 2 ;;
    --runs) runs=$2; shift 2 ;;
    --only) only=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --skip-build) build=0; shift ;;
    *) usage ;;
  esac
done

here=${0:A:h}
root=${here:h:h}
bundle=dev.abrahamgonzalez.rexduo
dd=${BENCH_DD:-${TMPDIR:-/tmp}/rex-bench-dd}
out=${out:-${TMPDIR:-/tmp}/rex-bench-$(date +%Y%m%d-%H%M%S)}
cols=60; rows=50   # fits an iPhone 17 at the default 11 pt font, so the terminal is drawn 1:1
mkdir -p "$out/results" "$out/scenarios"

if (( build )); then
  echo "Building Release into $dd …" >&2
  (cd "$root" && xcodegen generate >/dev/null)
  # ONLY_ACTIVE_ARCH: Release builds every simulator arch by default, and libghostty-vt's
  # simulator slice is arm64 only. Nothing else differs from an archive build's settings.
  xcodebuild -project "$root/RexConnect.xcodeproj" -scheme RexConnect -configuration Release \
    -destination "id=$sim" -derivedDataPath "$dd" -jobs 4 ONLY_ACTIVE_ARCH=YES \
    -skipPackagePluginValidation -skipMacroValidation build > "$out/build.log" 2>&1 \
    || { tail -30 "$out/build.log" >&2; exit 1; }
fi
app="$dd/Build/Products/Release-iphonesimulator/RexConnect.app"
[[ -d $app ]] || { echo "no app at $app" >&2; exit 1; }

xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl install "$sim" "$app"
node "$here/gen.mjs" "$out/scenarios" --cols $cols --rows $rows >&2

# One run: launches with the given arguments and waits for the probe's file.
run_one() {
  local name=$1 limit=$2; shift 2
  xcrun simctl terminate "$sim" $bundle >/dev/null 2>&1 || true
  local data; data=$(xcrun simctl get_app_container "$sim" $bundle data)
  local file="$data/Documents/perf/$name.json"
  rm -f "$file"
  xcrun simctl launch "$sim" $bundle -perfLog "$name" "$@" >/dev/null
  local waited=0
  until [[ -f $file ]]; do
    sleep 0.25
    (( waited += 1 ))
    if (( waited > limit * 4 )); then
      echo "  $name: no result after $limit s" >&2
      xcrun simctl terminate "$sim" $bundle >/dev/null 2>&1 || true
      return 0
    fi
  done
  cp "$file" "$out/results/$name.json"
  xcrun simctl terminate "$sim" $bundle >/dev/null 2>&1 || true
}

# name | file | extra replay arguments.
# "wire" runs cut the stream as the server does over Tailscale on the same host, measured with
# scripts/ghostty-tools/capture.mjs during `seq 1 200000`: about 1.8 KB a message, 2 MB/s.
scenarios=(
  "seq|seq.vt|-replayRate max"
  "seq-wire|seq.vt|-replayChunk 1800 -replayRate 2000000"
  "yes|yes.vt|-replayRate max"
  "yes-wire|yes.vt|-replayChunk 1800 -replayRate 2000000"
  "unicode|unicode.vt|-replayRate max"
  "top|top.timed|"
  "claude|claude.timed|"
)
engines=(swiftTerm ghostty)

for run in $(seq 1 $runs); do
  for s in $scenarios; do
    name=${s%%|*}; rest=${s#*|}; file=${rest%%|*}; extra=${rest#*|}
    [[ -z $only || ",$only," == *",$name,"* ]] || continue
    # Alternate which engine goes first, so drift over the session doesn't favour one.
    order=($engines); (( run % 2 == 0 )) && order=(${(Oa)engines})
    for engine in $order; do
      echo "run $run: $name $engine" >&2
      run_one "${name}__${engine}__${run}" 60 -replay "$out/scenarios/$file" -terminalEngine $engine \
        -replayCols $cols -replayRows $rows ${=extra}
    done
  done
done

if [[ -n $live ]]; then
  session=$(rex ls --json | LABEL=$live python3 -c 'import json,os,sys
print(next((s["session_id"] for s in json.load(sys.stdin)["sessions"] if s["label"] == os.environ["LABEL"]), ""))')
  [[ -n $session ]] || { echo "no session labelled $live" >&2; exit 1; }
  # A Release build starts with no servers; hand it this Mac's for the run (a launch argument).
  host=$(rex whoami --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["tailscale"]["dns_name"])')
  servers=$(HOST=$host python3 -c 'import json,os
s = json.dumps([{"id": "00000000-0000-4000-8000-0000000000BE", "name": "bench", "url": "https://" + os.environ["HOST"]}])
print("<" + s.encode().hex() + ">")')
  # The same content before every launch: 3000 lines of scrollback and a prompt.
  rex send -s "$session" $'clear; seq 1 3000\n'
  sleep 2
  for run in $(seq 1 5); do
    order=($engines); (( run % 2 == 0 )) && order=(${(Oa)engines})
    for engine in $order; do
      echo "live $run: $engine" >&2
      run_one "live__${engine}__${run}" 45 -autoOpen "$live" -sizing mirror -terminalEngine $engine -servers "$servers"
    done
  done
fi

echo "Results in $out/results" >&2
node "$here/report.mjs" "$out/results"
