#!/bin/zsh
# Waits until the App Store Connect app record for dev.abrahamgonzalez.rexduo exists,
# then archives + uploads build $BUILD on macdesk, and removes macdesk's build copy.
# Gives up (and still cleans macdesk) after MAX_HOURS.
set -u
cd ~/rexduo || exit 1
source ./.asc.env; export ASC_ISS
BUILD=${1:-3}; MAX_HOURS=${MAX_HOURS:-18}
LOG=~/rexduo/build/testflight.log; mkdir -p build
log() { echo "$(date '+%F %T') $*" | tee -a $LOG; }
cleanup_macdesk() { ssh macdesk 'rm -rf ~/rexduo-build' && log "removed macdesk:~/rexduo-build"; }
deadline=$(( $(date +%s) + MAX_HOURS*3600 ))
log "waiting for the App Store Connect record (check every 5 min, up to ${MAX_HOURS}h)"
while (( $(date +%s) < deadline )); do
  out=$(node scripts/asc.mjs GET '/v1/apps?filter[bundleId]=dev.abrahamgonzalez.rexduo&fields[apps]=name' 2>&1)
  if echo "$out" | grep -q '"type" : "apps"'; then
    log "app record found; uploading build $BUILD from macdesk"
    ssh macdesk "sudo launchctl asuser \$(id -u) sudo -u theabecaster /bin/zsh -lc '~/rexduo-build/ship.sh $BUILD'"
    ssh macdesk 'cat ~/rexduo-build/build/ship.log' > build/ship-macdesk.log
    if grep -qE "Upload succeeded|EXPORT SUCCEEDED|Uploaded" build/ship-macdesk.log; then
      log "UPLOADED build $BUILD. It shows in TestFlight after Apple processes it (~5-15 min)."
      cleanup_macdesk; exit 0
    fi
    log "upload FAILED, see ~/rexduo/build/ship-macdesk.log"; grep -E "error" build/ship-macdesk.log | head -5 | tee -a $LOG
    cleanup_macdesk; exit 1
  fi
  sleep 300
done
log "gave up waiting"; cleanup_macdesk; exit 2
