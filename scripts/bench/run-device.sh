#!/bin/zsh
# Runs the terminal benchmark on the iPhone Duo paired with the build Mac and prints the report.
#
#   scripts/bench/run-device.sh [--runs N] [--only a,b] [--out <dir>] [--fresh] [--skip-build]
#                               [--tag <prefix>] [--args '<launch arguments>'] [--live <session label>]
#                               [--remote <dir>] [--clean]
#
# Builds a Release copy of this tree with the BENCH condition on the build Mac (in ~/<remote>, default
# rexduo-build-bench) and installs it on the Duo, copies the scenarios into the app's
# Documents/bench, launches the app once per scenario and run with `-replay bench/<file>
# -perfLog <name>`, and copies each Documents/perf/<name>.json back to <out>/results
# (default build/bench-device). Resumable like run.sh: a result already there is skipped.
#
# --tag prefixes every result name (`<tag>-seq__1`), so builds or switches can share one results
# folder. --args adds launch arguments to every run (`--args '-drawables 2'`).
#
# --live <label> also opens that Rex session 5 times (--live-runs N) (cold launches, mirror sizing: no claim, no
# resize), after `seq 1 3000` in its pane, with `-perfIdle 10 -perfScroll 6`: time to first
# frame, the launch transition, 10 s of idle and a 6 s fling through the scrollback. The phone
# uses its saved servers, so the session must be on one of them, and it must be a throwaway
# session of your own (`rex session new zz-…`).
#
# --clean launches the installed bench build once with `-perfClean`, which deletes
# Documents/perf and Documents/bench on the phone and quits, and does nothing else.
# --stop only terminates the app.
#
# The phone must be unlocked and awake. A measured run turns auto-lock off until its process
# ends, so the phone stays awake from one run to the next and after the last one, with the app
# open: end a session with --stop. The device build and install are the same as
# scripts/install-duo.sh, plus BENCH; install the shipping build again with that script when done.
# REXDUO_BUILD_HOST names the build Mac (default macdesk), REXDUO_DEVICE the phone's UDID.
set -euo pipefail

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
runs=5; only=""; out=""; build=1; fresh=0; tag=""; extra=""; live=""; remote=rexduo-build-bench; clean=0; stop=0; liveRuns=5
while [[ $# -gt 0 ]]; do
  case $1 in
    --runs) runs=$2; shift 2 ;;
    --only) only=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --fresh) fresh=1; shift ;;
    --skip-build) build=0; shift ;;
    --tag) tag="$2-"; shift 2 ;;
    --args) extra=$2; shift 2 ;;
    --live) live=$2; shift 2 ;;
    --live-runs) liveRuns=$2; shift 2 ;;
    --remote) remote=$2; shift 2 ;;
    --clean) clean=1; shift ;;
    --stop) stop=1; shift ;;
    *) usage ;;
  esac
done

here=${0:A:h}
root=${here:h:h}
device=${REXDUO_DEVICE:-00008160-000602EC0EF00036}
host=${REXDUO_BUILD_HOST:-macdesk}
bundle=dev.abrahamgonzalez.rexduo
out=${out:-$root/build/bench-device}
cols=60; rows=50   # the simulator benchmark's grid, so the numbers compare
if (( fresh )); then rm -rf "$out/results"; fi
mkdir -p "$out/results" "$out/scenarios"
devicectl="/usr/bin/xcrun devicectl"
container=(--domain-type appDataContainer --domain-identifier $bundle)

launch() { ssh $host "$devicectl device process launch --device $device --terminate-existing $bundle -- $*" >/dev/null; }
terminate() {
  ssh $host "pid=\$($devicectl device info processes --device $device 2>/dev/null | awk '/RexDuo.app\/RexDuo\$/ {print \$1; exit}'); [ -n \"\$pid\" ] && $devicectl device process terminate --device $device --pid \$pid >/dev/null 2>&1; true" || true
}

if (( stop )); then terminate; exit 0; fi
if (( clean )); then
  launch -perfClean YES
  echo "cleaned Documents/perf and Documents/bench" >&2
  exit 0
fi

if (( build )); then
  echo "Building Release (BENCH) on $host in ~/$remote …" >&2
  (cd "$root" && REXDUO_BUILD_HOST=$host scripts/sync-macdesk.sh "$remote")
  # The same build as scripts/install-duo.sh, plus BENCH (`-replay`, `-perfLog`).
  ssh $host "sudo launchctl asuser \$(id -u) sudo -u \$USER zsh -lc 'cd ~/$remote && xcodebuild -project RexDuo.xcodeproj -scheme RexDuo -configuration Release -destination id=$device -derivedDataPath build/dd -allowProvisioningUpdates -allowProvisioningDeviceRegistration \"SWIFT_ACTIVE_COMPILATION_CONDITIONS=\\\$(inherited) BENCH\" build > build.log 2>&1' || { grep -E 'error:' ~/$remote/build.log | head -20; exit 1; }
$devicectl device install app --device $device ~/$remote/build/dd/Build/Products/Release-iphoneos/RexDuo.app | grep -E 'App installed'"
fi

# Scenarios: generated here, sent to the phone through the build Mac.
node "$here/gen.mjs" "$out/scenarios" --cols $cols --rows $rows >&2
ssh $host "mkdir -p ~/$remote-scenarios"
rsync -a "$out/scenarios/" "$host:$remote-scenarios/"
ssh $host "$devicectl device copy to --device $device ${container[*]} --source ~/$remote-scenarios --destination Documents/bench >/dev/null"

missing=0
# One run: launch with the arguments, wait for the probe's file, copy it back.
run_one() {
  local name=$1 limit=$2; shift 2
  if [[ -f "$out/results/$name.json" ]]; then
    echo "  $name: done before, skipped" >&2
    return 0
  fi
  echo "$name" >&2
  launch -perfLog "$name" "$@" || { echo "  $name: launch failed (is the phone unlocked?)" >&2; (( missing += 1 )); return 0; }
  # Poll on the build Mac: one ssh for the whole wait.
  if ssh $host "mkdir -p ~/$remote-results; for i in \$(seq 1 $limit); do sleep 1; $devicectl device copy from --device $device ${container[*]} --source Documents/perf/$name.json --destination ~/$remote-results/$name.json >/dev/null 2>&1 && exit 0; done; exit 1"; then
    scp -q "$host:$remote-results/$name.json" "$out/results/$name.json"
  else
    echo "  $name: no result after $limit s" >&2
    (( missing += 1 ))
  fi
}

# name | file | extra replay arguments (the simulator benchmark's scenarios, scripts/bench/run.sh).
scenarios=(
  "seq|seq.vt|-replayRate max"
  "seq-wire|seq.vt|-replayChunk 1800 -replayRate 2000000"
  "yes|yes.vt|-replayRate max"
  "yes-wire|yes.vt|-replayChunk 1800 -replayRate 2000000"
  "unicode|unicode.vt|-replayRate max"
  "top|top.timed|"
  "claude|claude.timed|"
)

for (( run = 1; run <= runs; run++ )); do
  for s in $scenarios; do
    name=${s%%|*}; rest=${s#*|}; file=${rest%%|*}; args=${rest#*|}
    [[ -z $only || ",$only," == *",$name,"* ]] || continue
    run_one "${tag}${name}__${run}" 40 -replay "bench/$file" -replayCols $cols -replayRows $rows ${=args} ${=extra}
  done
done

if [[ -n $live ]]; then
  session=$(rex ls --json | LABEL=$live python3 -c 'import json,os,sys
print(next((s["session_id"] for s in json.load(sys.stdin)["sessions"] if s["label"] == os.environ["LABEL"]), ""))')
  [[ -n $session ]] || { echo "no session labelled $live" >&2; exit 1; }
  rex send -s "$session" $'clear; seq 1 3000\n'
  sleep 2
  for (( run = 1; run <= liveRuns; run++ )); do
    run_one "${tag}live__${run}" 45 -autoOpen "$live" -sizing mirror -perfIdle 10 -perfScroll 6 ${=extra}
  done
fi

echo "Results in $out/results" >&2
node "$here/report.mjs" "$out/results" --partial || true
(( missing == 0 ))
