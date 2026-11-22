#!/bin/zsh
# Runs the terminal benchmark in a simulator, prints the report and checks it against the
# budgets in scripts/bench/budgets.mjs. Exit status 1 when a budget is passed or a run failed.
#
#   scripts/bench/run.sh <simulator id> [--live <session label>] [--switch <session label>]
#                        [--warm <session label>] [--runs N] [--only a,b] [--out <dir>] [--fresh]
#                        [--skip-build]
#
# Builds the app once (Release), then for every scenario and run launches it with
# `-replay <file> -perfLog <name>`, waits for the result file in the app's Documents/perf and
# copies it to <out>/results. Replay runs touch no server. About 4 minutes for the 21 replay
# runs after the build; --live adds about 1. Every `unicode` run follows an unmeasured one, which
# likely warms the simulator's fallback fonts.
#
# Results land in <out>/results, one JSON per run (default <out>: build/bench in the repo,
# an ignored directory). The report is printed at the end; `node scripts/bench/report.mjs
# <out>/results` prints and checks it again.
#
# Resumable: a run whose result file is already there is skipped, so after an interruption the
# same command goes on where it stopped. --fresh deletes the old results first; use it after
# changing the code.
#
# --live <session label> also measures time to first frame on a real pane: 5 cold launches
# with `-autoOpen <label> -sizing mirror`, after `seq 1 3000` in that session's pane.
# The app then connects to the local Rex server and opens that session, so the label must be a
# throwaway session of your own (`rex session new zz-…`). Mirror sizing never claims or
# resizes the pane.
#
# --switch <session label> measures pane switches on real panes, in fit mode: the session's
# first tab must hold two panes side by side (`rex split`), which a phone shows one at a time.
# Each run opens the tab and switches between the two panes 10 times, 1.5 s apart, as a swipe
# does: 3 runs with no added delay (`switch0`) and 3 with a simulated round trip of 150 ms
# (`switch150`, `-netDelay`). Fit mode claims and resizes both panes, so the session must be a
# throwaway one of your own.
#
# --warm <session label> measures what two panes that stream unseen cost: the session's first
# tab must hold exactly three panes side by side, the first two running a program that writes
# steadily (under 64 KB/s, or they park). Each run walks to the first pane and back to the
# third, which leaves the first two warm, then sits still for 10 s (`warm`: main-thread time,
# CPU, energy). In mirror mode, so no claim is given back in those 10 s: the sidebar's update
# for that is the app's, not the warm panes'.
#
# The app is terminated after every run and when the script ends or is interrupted, which also
# drops its connection to the server.
#
# A full run (no --only) ends with scripts/bench/filter.sh (the stream's filter against the one
# it replaced, measured on the Mac by a RexKit test, about 20 s) and scripts/bench/flood.sh (how
# long a title takes to show during a flood of progress reports, an app test in the simulator,
# a Debug build of its own the first time).
#
# Environment: BENCH_DD (derived data, default build/dd-bench).
set -euo pipefail

self=$0   # inside a function, $0 is the function's name
usage() { sed -n '2,49p' "$self" | sed 's/^# \{0,1\}//'; exit 2; }
[[ $# -ge 1 ]] || usage
sim=$1; shift
live=""; switch=""; warm=""; runs=3; only=""; out=""; build=1; fresh=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --live) live=$2; shift 2 ;;
    --switch) switch=$2; shift 2 ;;
    --warm) warm=$2; shift 2 ;;
    --runs) runs=$2; shift 2 ;;
    --only) only=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --fresh) fresh=1; shift ;;
    --skip-build) build=0; shift ;;
    *) usage ;;
  esac
done

here=${0:A:h}
root=${here:h:h}
bundle=dev.abrahamgonzalez.rexduo
dd=${BENCH_DD:-$root/build/dd-bench}
# Absolute, against the caller's directory: the app reads the scenarios by this path, and a
# relative one would be looked up in its own container.
out=${${out:-$root/build/bench}:a}
if (( fresh )); then rm -rf "$out/results"; fi
cols=60; rows=50   # fits an iPhone 17 at the default 11 pt font, so the terminal is drawn 1:1
mkdir -p "$out/results" "$out/scenarios"

# Never leave the app running (it may hold a connection to a real pane).
cleanup() { xcrun simctl terminate "$sim" $bundle >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

if (( build )); then
  echo "Building Release into $dd …" >&2
  (cd "$root" && xcodegen generate >/dev/null)
  # ONLY_ACTIVE_ARCH: Release builds every simulator arch by default, and libghostty-vt's
  # simulator slice is arm64 only.
  # BENCH: the compilation condition that keeps `-replay` and `-perfLog` in this optimized
  # build (`#if DEBUG || BENCH`). It is set here, for this build only; the shipped Release
  # configuration doesn't have it, so a shipped app has neither argument.
  # Nothing else differs from an archive build's settings.
  xcodebuild -project "$root/RexDuo.xcodeproj" -scheme RexDuo -configuration Release \
    -destination "id=$sim" -derivedDataPath "$dd" -jobs 4 ONLY_ACTIVE_ARCH=YES \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BENCH' \
    build > "$out/build.log" 2>&1 \
    || { tail -30 "$out/build.log" >&2; exit 1; }
fi
app="$dd/Build/Products/Release-iphonesimulator/RexDuo.app"
[[ -d $app ]] || { echo "no app at $app" >&2; exit 1; }

xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl install "$sim" "$app"
node "$here/gen.mjs" "$out/scenarios" --cols $cols --rows $rows >&2
# `predict` replays recordings kept with the tests: a pane's stream after `seq 1 3000` (its
# snapshot, 80×24) and a typing session at a zsh prompt (scripts/record-echo-fixtures.py).
cp "$root/Packages/RexKit/Tests/RexKitTests/Fixtures/stream-scroll.bin" "$out/scenarios/predict.bin"
cp "$root/Packages/RexKit/Tests/RexKitTests/Fixtures/stream-scroll.bin.nonce" "$out/scenarios/predict.bin.nonce"
cp "$root/RexDuoTests/Fixtures/echo/echo-zsh-typing.json" "$out/scenarios/predict.json"

# One run: launches with the given arguments and waits for the probe's file.
missing=0
run_one() {
  local name=$1 limit=$2; shift 2
  if [[ -f "$out/results/$name.json" ]]; then
    echo "  $name: done before, skipped" >&2
    return 0
  fi
  echo "$name" >&2
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
      (( missing += 1 ))
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
  # Find open, with the same budgets as the runs without it: stepping 20 matches
  # and a fling through the scrollback where the replay allows one, and a run at the 10k cap.
  "seq-find|seq.vt|-replayRate max -findTest 99 -findSteps 20 -perfScroll 6"
  "unicode-find|unicode.vt|-replayRate max -findTest e -findSteps 20"
  "claude-find|claude.timed|-findTest e -findSteps 20"
  "cap-find|cap.vt|-replayRate max -findTest 99"
  # Predicted echo: a pane with history on a scripted link with a 150 ms round trip, typed into
  # from a recording, three times over: the gate turns predictions on during the first, so the
  # other two are guessed from their first line on. 8 pt draws the recording's 80 columns 1:1.
  "predict|predict.bin|-echoScript predict.json -echoLoops 3 -replayFontSize 8"
  # The same pane, script and link with no gate: what the scenario costs without predicted echo.
  "predict-off|predict.bin|-echoScript predict.json -echoLoops 3 -replayFontSize 8 -predict never"
  # A fast link (5 ms): the gate is there and stays off. Beside it the same with no gate: a
  # key must cost the main thread the same in both.
  "predict-fast|predict.bin|-echoScript predict.json -echoLoops 3 -echoDelay 5 -replayFontSize 8"
  "predict-fast-off|predict.bin|-echoScript predict.json -echoLoops 3 -echoDelay 5 -replayFontSize 8 -predict never"
)

# A warm-up for `unicode`. Its time to the final frame is likely mostly CoreText loading its fallback
# fonts (CJK, emoji) in the new process, and on a simulator in its first minutes after its first
# boot that load is slow unless a process did the same seconds before: 110 to 310 ms with one or
# two stalls between frames, whatever the code, against 16 to 57 ms right after another launch
# and on a simulator that has settled. So an unmeasured launch goes right before every measured
# one. Its result is thrown away: it never reaches <out>/results, so no report or median sees it.
warm_up() {
  local name=unicode__warmup data file waited=0
  echo "unicode warm-up (not measured)" >&2
  xcrun simctl terminate "$sim" $bundle >/dev/null 2>&1 || true
  data=$(xcrun simctl get_app_container "$sim" $bundle data)
  file="$data/Documents/perf/$name.json"
  rm -f "$file"
  xcrun simctl launch "$sim" $bundle -perfLog $name -replay "$out/scenarios/unicode.vt" \
    -replayCols $cols -replayRows $rows -replayRate max >/dev/null
  until [[ -f $file ]] || (( waited >= 240 )); do sleep 0.25; (( waited += 1 )); done
  [[ -f $file ]] || echo "  warm-up: no result after 60 s, going on" >&2
  rm -f "$file"
  xcrun simctl terminate "$sim" $bundle >/dev/null 2>&1 || true
}
for run in $(seq 1 $runs); do
  for s in $scenarios; do
    name=${s%%|*}; rest=${s#*|}; file=${rest%%|*}; extra=${rest#*|}
    [[ -z $only || ",$only," == *",$name,"* ]] || continue
    if [[ $name == unicode* && ! -f "$out/results/${name}__${run}.json" ]]; then warm_up; fi
    run_one "${name}__${run}" 60 -replay "$out/scenarios/$file" -replayCols $cols -replayRows $rows ${=extra}
  done
done

# The id of the session with this label on this Mac's server; empty when there is none.
session_id() {
  rex ls --json | LABEL=$1 python3 -c 'import json,os,sys
print(next((s["session_id"] for s in json.load(sys.stdin)["sessions"] if s["label"] == os.environ["LABEL"]), ""))'
}
# A Release build starts with no servers; hand it this Mac's for the run (a launch argument).
bench_servers() {
  local host
  host=$(rex whoami --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["tailscale"]["dns_name"])')
  HOST=$host python3 -c 'import json,os
s = json.dumps([{"id": "00000000-0000-4000-8000-0000000000BE", "name": "bench", "url": "https://" + os.environ["HOST"]}])
print("<" + s.encode().hex() + ">")'
}

if [[ -n $live ]]; then
  session=$(session_id "$live")
  [[ -n $session ]] || { echo "no session labelled $live" >&2; exit 1; }
  servers=$(bench_servers)
  # The same content before every launch: 3000 lines of scrollback and a prompt.
  rex send -s "$session" $'clear; seq 1 3000\n'
  sleep 2
  for run in $(seq 1 5); do
    run_one "live__${run}" 45 -autoOpen "$live" -sizing mirror -servers "$servers"
  done
fi

# Before a launch that claims panes: time for the server to see the last launch's client gone
# and give its panes back, so every run starts from the same state.
settle() {
  xcrun simctl terminate "$sim" $bundle >/dev/null 2>&1 || true
  [[ -f "$out/results/$1.json" ]] || sleep 9
}

if [[ -n $switch ]]; then
  [[ $switch == zz-* ]] || { echo "--switch takes a throwaway session whose label starts with zz-" >&2; exit 1; }
  [[ -n $(session_id "$switch") ]] || { echo "no session labelled $switch" >&2; exit 1; }
  servers=$(bench_servers)
  for run in $(seq 1 $runs); do
    for delay in 0 150; do
      [[ -z $only || ",$only," == *",switch$delay,"* ]] || continue
      settle "switch${delay}__${run}"
      run_one "switch${delay}__${run}" 90 -autoOpen "$switch" -servers "$servers" \
        -perfSwitch 10 -perfSwitchType x -netDelay $delay
    done
  done
fi

if [[ -n $warm ]]; then
  [[ $warm == zz-* ]] || { echo "--warm takes a throwaway session whose label starts with zz-" >&2; exit 1; }
  [[ -n $(session_id "$warm") ]] || { echo "no session labelled $warm" >&2; exit 1; }
  servers=$(bench_servers)
  for run in $(seq 1 $runs); do
    [[ -z $only || ",$only," == *",warm,"* ]] || continue
    settle "warm__${run}"
    run_one "warm__${run}" 90 -autoOpen "$warm" -servers "$servers" \
      -sizing mirror -perfSwitch 4 -perfSwitchWalk YES -perfIdle 10
  done
fi

echo "Results in $out/results" >&2
# With --only, the scenarios left out are not missing.
failed=0
node "$here/report.mjs" "$out/results" ${only:+--partial} || failed=1
if (( missing )); then
  echo "$missing run(s) wrote no result" >&2
  failed=1
fi
# The stream's filter against the one it replaced: on the Mac, no simulator (filter.sh).
if [[ -z $only ]]; then
  "$here/filter.sh" || failed=1
  # A title's lag during a flood of progress reports: an app test, in the same simulator.
  "$here/flood.sh" "$sim" || failed=1
fi
exit $failed
