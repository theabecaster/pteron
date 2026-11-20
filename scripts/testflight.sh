#!/bin/zsh
# Ships this checkout to TestFlight: copies it to the build Mac, archives and uploads there, waits
# for App Store Connect to process the build, sets its "What to Test" text, submits it to Beta App
# Review, waits for approval and adds it to the testers' group. See docs/release.md, TestFlight.
#
# Usage: scripts/testflight.sh <notes-file> [--build N] [--skip-upload] [--dry-run]
#   notes-file     the "What to Test" text, read once at the start (at most 4000 characters)
#   --build N      the build number (default: date +%y%m%d%H%M); higher than the last upload
#   --skip-upload  don't sync or archive: carry on with build N, already uploaded (needs --build)
#   --dry-run      print the steps and check the setup with read-only App Store Connect calls;
#                  nothing is copied, built, uploaded or changed
#
# Environment:
#   TESTFLIGHT_APP_ID    the app's App Store Connect id
#   TESTFLIGHT_GROUP_ID  the beta group the build is added to
#   REXDUO_BUILD_HOST    the build Mac's ssh host (as for scripts/sync-macdesk.sh)
#   ASC_ENV              the file that sets ASC_ISS (default: .asc.env in the main checkout)
APP_ID=${TESTFLIGHT_APP_ID:-6835558559}
GROUP_ID=${TESTFLIGHT_GROUP_ID:-8d106899-b4af-4db5-8f75-57aa55db263f}
HOST=${REXDUO_BUILD_HOST:-macdesk}

# zsh reads a script as it runs it, so an edit to this file during a run (a pull, a branch switch)
# would change the run. It runs from a copy instead, made before anything else is read.
if [[ -z ${_TESTFLIGHT_REPO:-} ]]; then
  _copy=$(mktemp "${TMPDIR:-/tmp}/testflight.XXXXXX") || exit 1
  cp "${0:A}" "$_copy" || { rm -f "$_copy"; exit 1; }
  _TESTFLIGHT_REPO=${0:A:h:h} _TESTFLIGHT_COPY=$_copy exec /bin/zsh "$_copy" "$@"
fi
REPO=$_TESTFLIGHT_REPO
# zsh holds the copy open while it reads it, so it goes now and no exit or signal can leave it.
rm -f "$_TESTFLIGHT_COPY"
unset _TESTFLIGHT_REPO _TESTFLIGHT_COPY
set -u -o pipefail

usage() {
  echo "usage: scripts/testflight.sh <notes-file> [--build N] [--skip-upload] [--dry-run]" >&2
  exit 2
}
die() { echo "testflight.sh: $*" >&2; exit 1; }
say() { print -r -- "$(date +%H:%M:%S) $*"; }

NOTES_FILE="" BUILD="" SKIP_UPLOAD=0 DRY=0
while (( $# )); do
  case $1 in
    --build) (( $# >= 2 )) || usage; BUILD=$2; shift 2 ;;
    --skip-upload) SKIP_UPLOAD=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -*) usage ;;
    *) [[ -z $NOTES_FILE ]] || usage; NOTES_FILE=$1; shift ;;
  esac
done
[[ -n $NOTES_FILE ]] || usage
(( SKIP_UPLOAD )) && [[ -z $BUILD ]] && die "--skip-upload needs --build with the uploaded build number"
BUILD=${BUILD:-$(date +%y%m%d%H%M)}
[[ $BUILD =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || die "build number '$BUILD' is not like 42 or 1.2.3"

# The notes are read here, once: the file can change afterwards without changing this release.
[[ -f $NOTES_FILE ]] || die "no notes file at $NOTES_FILE"
NOTES=$(<$NOTES_FILE)
[[ -n ${NOTES//[[:space:]]/} ]] || die "$NOTES_FILE is empty"
(( ${#NOTES} <= 4000 )) || die "$NOTES_FILE has ${#NOTES} characters; App Store Connect takes 4000"

cd "$REPO" || exit 1
command -v node >/dev/null || die "node is needed for scripts/asc.mjs"
# .asc.env sits at the top of the main checkout; a worktree finds it through the shared repository.
# Its values are exported for asc.mjs and never printed.
MAIN_CHECKOUT="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd || echo "$REPO")"
ASC_ENV=${ASC_ENV:-$MAIN_CHECKOUT/.asc.env}
[[ -f $ASC_ENV ]] || die "no $ASC_ENV (it sets ASC_ISS for scripts/asc.mjs)"
set -a; source "$ASC_ENV" >/dev/null; set +a
[[ -n ${ASC_ISS:-} ]] || die "$ASC_ENV does not set ASC_ISS"

# asc METHOD PATH [BODY]: prints the response body, and fails with the status and Apple's error
# text unless the status is 2xx. asc.mjs prints the status on its first line and cuts the body at
# 4000 characters, so every GET asks for only the fields it reads.
asc() {
  local out code body
  out=$(node scripts/asc.mjs "$@") || { echo "testflight.sh: $1 $2 did not complete" >&2; return 1; }
  code=${out%%$'\n'*}
  [[ $out == *$'\n'* ]] && body=${out#*$'\n'} || body=""
  if [[ $code != 2?? ]]; then
    echo "testflight.sh: $1 $2 answered $code: $(print -r -- "$body" | json 'd.errors?.map(e=>e.detail||e.title).join("; ")' 2>/dev/null)" >&2
    return 1
  fi
  print -r -- "$body"
}
# json EXPR: reads JSON on stdin and prints EXPR of it (`d` is the parsed value); empty for null.
json() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const d=JSON.parse(s);const v=new Function("d","return ("+process.argv[1]+")")(d);console.log(v??"")})' "$1"
}
# The build's id and processing state, "<id> <state>", or nothing while App Store Connect has no
# such build yet.
build_state() {
  asc GET "/v1/builds?filter[app]=$APP_ID&filter[version]=$BUILD&fields[builds]=processingState,version&limit=1" \
    | json 'd.data?.[0] ? d.data[0].id+" "+d.data[0].attributes.processingState : ""'
}
# The build's Beta App Review state, or nothing when it has not been submitted.
review_state() {
  asc GET "/v1/builds/$1/betaAppReviewSubmission?fields[betaAppReviewSubmissions]=betaReviewState" 2>/dev/null \
    | json 'd.data?.attributes?.betaReviewState' 2>/dev/null
}

SHIP="sudo launchctl asuser \$(id -u) sudo -u \$USER zsh -lc '~/rexduo-build/scripts/ship-macdesk.sh $BUILD'"

if (( DRY )); then
  say "dry run: build $BUILD of $(git rev-parse --abbrev-ref HEAD) $(git rev-parse --short HEAD), app $APP_ID, group $GROUP_ID"
  [[ -z $(git status --porcelain) ]] || say "note: the tree has uncommitted changes, and the copy takes them"
  APP=$(asc GET "/v1/apps/$APP_ID?fields[apps]=bundleId,name" | json 'd.data.attributes.name+" ("+d.data.attributes.bundleId+")"') \
    || die "App Store Connect has no app $APP_ID for this key"
  say "app: $APP"
  GROUP=$(asc GET "/v1/betaGroups/$GROUP_ID?fields[betaGroups]=name" | json 'd.data.attributes.name') \
    || die "App Store Connect has no beta group $GROUP_ID"
  say "group: $GROUP"
  EXISTING=$(build_state) || die "could not look up build $BUILD"
  if (( SKIP_UPLOAD )); then
    [[ -n $EXISTING ]] || die "--skip-upload, but App Store Connect has no build $BUILD"
    LOCALES=$(asc GET "/v1/builds/${EXISTING%% *}/betaBuildLocalizations?fields[betaBuildLocalizations]=locale" \
      | json 'd.data.map(x=>x.attributes.locale).join(" ")')
    say "build $BUILD: ${EXISTING#* }, review: $(review_state ${EXISTING%% *}), localizations: ${LOCALES:-none}"
  else
    [[ -z $EXISTING ]] || die "App Store Connect already has build $BUILD; pick a higher number"
    say "would run: scripts/sync-macdesk.sh"
    say "would run: ssh $HOST \"$SHIP\""
  fi
  say "would poll build $BUILD every 30 s until VALID (up to 45 min)"
  say "would set whatsNew (${#NOTES} characters from $NOTES_FILE)"
  say "would submit for Beta App Review and poll every 60 s until APPROVED (up to 2 h)"
  say "would add the build to group $GROUP_ID (5 tries, 30 s apart)"
  exit 0
fi

say "build $BUILD of $(git rev-parse --abbrev-ref HEAD) $(git rev-parse --short HEAD)"
if (( ! SKIP_UPLOAD )); then
  [[ -z $(build_state) ]] || die "App Store Connect already has build $BUILD; pick a higher number"
  say "copying the tree to $HOST"
  scripts/sync-macdesk.sh || die "scripts/sync-macdesk.sh failed"
  say "archiving and uploading on $HOST (log: ~/rexduo-build/build/ship.log there)"
  if ! ssh "$HOST" "$SHIP"; then
    ssh "$HOST" 'tail -5 ~/rexduo-build/build/ship.log' >&2
    die "ship-macdesk.sh failed on $HOST"
  fi
fi

ID=""
for i in {1..90}; do
  R=$(build_state) || R=""
  ST=${R#* }
  [[ -n $R ]] && ID=${R%% *}
  say "processing $i: ${ST:-not there yet}"
  [[ $ST == VALID ]] && break
  [[ $ST == (INVALID|FAILED) ]] && die "build $BUILD is $ST in App Store Connect"
  sleep 30
done
[[ -n $ID && $ST == VALID ]] || die "build $BUILD did not become VALID in 45 minutes"

# Each build has one localization per test language; App Store Connect usually makes en-US.
LOCS=$(asc GET "/v1/builds/$ID/betaBuildLocalizations?fields[betaBuildLocalizations]=locale" \
  | json 'd.data.map(x=>x.id).join(" ")') || die "could not read the build's localizations"
NOTES_JSON=$(print -r -- "$NOTES" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>console.log(JSON.stringify(s.replace(/\n$/,""))))')
if [[ -z $LOCS ]]; then
  asc POST /v1/betaBuildLocalizations "{\"data\":{\"type\":\"betaBuildLocalizations\",\"attributes\":{\"locale\":\"en-US\",\"whatsNew\":$NOTES_JSON},\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$ID\"}}}}}" >/dev/null \
    || die "could not set the notes"
else
  for LOC in ${=LOCS}; do
    asc PATCH "/v1/betaBuildLocalizations/$LOC" "{\"data\":{\"type\":\"betaBuildLocalizations\",\"id\":\"$LOC\",\"attributes\":{\"whatsNew\":$NOTES_JSON}}}" >/dev/null \
      || die "could not set the notes"
  done
fi
say "notes set"

# A run with --skip-upload may find the build already submitted.
RS=$(review_state $ID)
if [[ -z $RS ]]; then
  asc POST /v1/betaAppReviewSubmissions "{\"data\":{\"type\":\"betaAppReviewSubmissions\",\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$ID\"}}}}}" >/dev/null \
    || die "could not submit build $BUILD for Beta App Review"
  say "submitted for Beta App Review"
fi
for i in {1..120}; do
  RS=$(review_state $ID)
  say "review $i: ${RS:-unknown}"
  [[ $RS == APPROVED ]] && break
  [[ $RS == REJECTED ]] && die "Beta App Review rejected build $BUILD"
  sleep 60
done
[[ $RS == APPROVED ]] || die "build $BUILD was not approved in 2 hours; rerun with --skip-upload --build $BUILD"

# The group sometimes refuses a build for a while after approval.
for i in {1..5}; do
  if asc POST "/v1/betaGroups/$GROUP_ID/relationships/builds" "{\"data\":[{\"type\":\"builds\",\"id\":\"$ID\"}]}" >/dev/null; then
    say "added to the group"
    say "done: build $BUILD ($ID)"
    exit 0
  fi
  sleep 30
done
die "could not add build $BUILD to group $GROUP_ID"
