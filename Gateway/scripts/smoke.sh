#!/usr/bin/env bash
# Checks a deployed gateway end to end, without a real device.
#
#   scripts/smoke.sh https://rexduo-push.<subdomain>.workers.dev
#
# It registers a token no device has, mints a secret for it as a phone does for a helper, and
# pushes with that secret. Apple answering BadDeviceToken proves the Worker reached APNs over
# HTTP/2 and that Apple accepted the provider JWT (a bad key would give 403 instead). Nothing
# is delivered anywhere. The gateway marks the registration dead, which the next step checks,
# and the last steps delete it as its owner, so a run leaves nothing behind.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <base-url>" >&2; exit 2; }
BASE="${1%/}"
# 64 hex characters that are no device's token.
FAKE_TOKEN="$(printf 'deadbeef%.0s' 1 2 3 4 5 6 7 8)"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

fail() {
  echo "SMOKE FAILED: $*" >&2
  # Only answers to the fake registration are ever here, and never its credentials.
  echo "last response: $(head -c 400 "$body" | sed -E 's/"(owner_key|push_secret)" *: *"[^"]*"/"\1":"…"/g')" >&2
  exit 1
}

# call METHOD PATH [curl args…]: writes the body to $body and prints the status.
call() {
  local method="$1" path="$2"
  shift 2
  curl --silent --show-error --max-time 30 --output "$body" --write-out '%{http_code}' \
    --request "$method" "$BASE$path" "$@" || true
}

# field NAME: a top-level string, number or boolean of the JSON in $body (empty when absent).
field() {
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$1" '.[$k] // empty' "$body" 2>/dev/null || true
  else
    python3 -c '
import json, sys
try:
    value = json.load(open(sys.argv[1])).get(sys.argv[2], "")
except Exception:
    value = ""
print(str(value).lower() if isinstance(value, bool) else value)
' "$body" "$1"
  fi
}

expect() {
  local what="$1" want="$2" got="$3"
  [ "$got" = "$want" ] || fail "$what: expected $want, got ${got:-nothing}"
}

# A notice as the helper sends one: the gateway passes on that shape only. Kept in single
# quotes on its own line, because macOS's bash 3.2 misreads escaped quotes inside "$( … )".
PUSH_BODY='{"payload":{"aps":{"alert":{"title":"Rex DUO","body":"Gateway smoke test"},"interruption-level":"active","thread-id":"block:smoke","category":"NOTICE","sound":"default"},"server":"https://rex.example.ts.net","session_id":"session:smoke","block_id":"block:smoke"},"push_type":"alert","priority":10}'

push() {
  call POST /v1/push --header "authorization: Bearer $1" --header 'content-type: application/json' \
    --data "$PUSH_BODY"
}

echo "1. GET /v1/health"
expect "health status" 200 "$(call GET /v1/health)"
expect "health ok" true "$(field ok)"
echo "   version $(field version)"

echo "2. POST /v1/devices (a fake sandbox token)"
# JSON bodies are built with printf into a variable, outside any command substitution that
# also quotes: macOS's bash 3.2 misreads escaped quotes inside "$( … )".
registration="$(printf '{"apns_token":"%s","environment":"sandbox"}' "$FAKE_TOKEN")"
status="$(call POST /v1/devices --header 'content-type: application/json' --data "$registration")"
expect "registration status" 201 "$status"
device="$(field device_id)"
owner="$(field owner_key)"
[ -n "$device" ] || fail "registration returned no device_id"
[ ${#owner} -eq 43 ] || fail "registration returned no owner_key"
[ -z "$(field push_secret)" ] || fail "registration returned a push_secret; secrets are minted per helper now"

echo "3. POST /v1/devices/{id}/secrets (the secret a helper would get)"
label='{"label":"smoke test"}'
status="$(call POST "/v1/devices/$device/secrets" --header "authorization: Bearer $owner" \
  --header 'content-type: application/json' --data "$label")"
expect "secret status" 201 "$status"
secret="$(field push_secret)"
[ ${#secret} -eq 43 ] || fail "minting returned no push_secret"
[ -n "$(field secret_id)" ] || fail "minting returned no secret_id"

echo "4. POST /v1/push (Apple must refuse the token)"
status="$(push "$secret")"
if [ "$status" = 502 ]; then
  fail "the gateway could not push: $(field error) (Apple's answer: $(field status) $(field reason)). apns_unreachable means the HTTP/2 path to Apple is broken (README, If Apple's HTTP/2 path breaks); a 403 from Apple means the key, key id or team id is wrong"
fi
expect "push status" 410 "$status"
expect "push error" unregistered "$(field error)"
expect "Apple's reason" BadDeviceToken "$(field reason)"

echo "5. POST /v1/push again (the gateway must answer for the dead token itself)"
expect "second push status" 410 "$(push "$secret")"
expect "second push error" unregistered "$(field error)"
[ -z "$(field reason)" ] || fail "the second push carried a reason, so it went to Apple again"

echo "6. GET /v1/devices/{id} (the owner still reaches the device)"
status="$(call GET "/v1/devices/$device" --header "authorization: Bearer $owner")"
expect "device status" 200 "$status"
expect "device environment" sandbox "$(field environment)"

echo "7. DELETE /v1/devices/{id} (the owner removes it)"
status="$(call DELETE "/v1/devices/$device" --header "authorization: Bearer $owner")"
expect "delete status" 204 "$status"
status="$(call GET "/v1/devices/$device" --header "authorization: Bearer $owner")"
expect "device status after the delete" 401 "$status"
expect "device error" unauthorized "$(field error)"

echo "SMOKE OK: $BASE reaches APNs, Apple accepts its key, and a dead token stops its device's pushes."
