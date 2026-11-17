#!/bin/zsh
# Runs the terminal benchmark in a simulator, prints the report and checks it against the
# budgets in scripts/bench/budgets.mjs. Exit status 1 when a budget is passed or a run failed.
#
#   scripts/bench/run.sh <simulator id> [--live <session label>] [--runs N] [--only a,b]
#                        [--out <dir>] [--fresh] [--skip-build]
#
# Builds the app once (Release), then for every scenario and run launches it with
# `-replay <file> -perfLog <name>`, waits for the result file in the app's Documents/perf and
# copies it to <out>/results. Replay runs touch no server. About 4 minutes for the 21 replay
# runs after the build; --live adds about 1.
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
# The app is terminated after every run and when the script ends or is interrupted, which also
# drops its connection to the server.
#
# Environment: BENCH_DD (derived data, default build/dd-bench).
set -euo pipefail

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[[ $# -ge 1 ]] || usage
sim=$1; shift
live=""; runs=3; only=""; out=""; build=1; fresh=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --live) live=$2; shift 2 ;;
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
out=${out:-$root/build/bench}
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
  xcodebuild -project "$root/RexConnect.xcodeproj" -scheme RexConnect -configuration Release \
    -destination "id=$sim" -derivedDataPath "$dd" -jobs 4 ONLY_ACTIVE_ARCH=YES \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BENCH' \
    build > "$out/build.log" 2>&1 \
    || { tail -30 "$out/build.log" >&2; exit 1; }
fi
app="$dd/Build/Products/Release-iphonesimulator/RexConnect.app"
[[ -d $app ]] || { echo "no app at $app" >&2; exit 1; }

xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl install "$sim" "$app"
node "$here/gen.mjs" "$out/scenarios" --cols $cols --rows $rows >&2

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
)

for run in $(seq 1 $runs); do
  for s in $scenarios; do
    name=${s%%|*}; rest=${s#*|}; file=${rest%%|*}; extra=${rest#*|}
    [[ -z $only || ",$only," == *",$name,"* ]] || continue
    run_one "${name}__${run}" 60 -replay "$out/scenarios/$file" -replayCols $cols -replayRows $rows ${=extra}
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
    run_one "live__${run}" 45 -autoOpen "$live" -sizing mirror -servers "$servers"
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
exit $failed
