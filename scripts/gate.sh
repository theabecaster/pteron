#!/bin/zsh
# The check before a release: the app's tests and a Release build on a fresh simulator, the
# warnings from our code, and scripts/check-brand.sh. Exits 0 only when all of them pass.
# Usage: scripts/gate.sh
#   GATE_DEVICE   the simulator's device type (default "iPhone 17 Pro")
#   GATE_RUNTIME  its runtime identifier (default: the newest plain iOS runtime installed)
# The simulator is deleted at the end, and so is build/ (only the gate's own folders in it when
# build/ was there before). When something fails, the logs are kept in a temporary folder whose
# path is printed.
cd "${0:A:h:h}" || exit 1
setopt pipefail

DEVICE=${GATE_DEVICE:-iPhone 17 Pro}
# Plain runtimes only: a device-specific one (…SimRuntime.iOS-27-2-iPhone19-4) runs one model.
RT=${GATE_RUNTIME:-$(xcrun simctl list runtimes available | awk '$NF ~ /SimRuntime\.iOS-[0-9]+(-[0-9]+)*$/ {rt=$NF} END {print rt}')}
[[ -n $RT ]] || { echo "gate.sh: no iOS simulator runtime installed" >&2; exit 1; }

HAD_BUILD=0; [[ -d build ]] && HAD_BUILD=1
mkdir -p build
SIM=""
cleanup() {
  [[ -n $SIM ]] && xcrun simctl delete $SIM
  if (( HAD_BUILD )); then rm -rf build/dd-gate build/dd-gate-rel build/gate-test.log build/gate-rel.log
  else rm -rf build; fi
}
trap 'cleanup; exit 130' INT TERM

SIM=$(xcrun simctl create "zz-gate-$$" "$DEVICE" $RT) || { SIM=""; cleanup; echo "gate.sh: could not create a $DEVICE simulator on $RT" >&2; exit 1; }
echo "simulator $SIM ($DEVICE, $RT)"
FAILED=()

xcodegen generate -q || FAILED+=(xcodegen)

# The package tests, one package after the other. gate-branch runs this script under
# `taskpolicy -b`, and the children inherit that background priority; a wall-time test
# (EarlySocketStreamTests) can pass there when it should fail, so the script puts itself back
# to normal priority first. Either package failing fails the gate and names the package.
taskpolicy -B -p $$ 2>/dev/null
for pkg in RexKit RexGlance; do
  swift test --package-path "Packages/$pkg" > "build/gate-$pkg.log" 2>&1
  rc=$?; echo "$pkg tests: exit $rc"
  if (( rc != 0 )); then
    FAILED+=(${(L)pkg})
    grep -E "error: -\[|✘ |failed \(|Test run with .* failed" "build/gate-$pkg.log" | head -10
  fi
done

# The Mac's load when the tests begin, for reading a failure afterwards.
echo "load before tests: $(sysctl -n vm.loadavg)"
# One test process, never parallel workers: with two the 1-minute load passes 400 on a 10-core
# Mac and about 20 tests fail on their time limits, with one it stays near 140 and none does.
xcodebuild -project Pteron.xcodeproj -scheme Pteron -destination id=$SIM -derivedDataPath build/dd-gate \
  -parallel-testing-enabled NO test > build/gate-test.log 2>&1
rc=$?; echo "tests: exit $rc"; (( rc == 0 )) || FAILED+=(tests)
grep -E "Executed [0-9]+ tests|Test run with|\*\* TEST|error:" build/gate-test.log | tail -4
grep -E "✘|failed|recorded an issue|Expectation failed|error:" build/gate-test.log | grep -v "0 failures" | head -20

# ONLY_ACTIVE_ARCH: the framework's simulator slice is arm64 only.
xcodebuild -project Pteron.xcodeproj -scheme Pteron -configuration Release -destination id=$SIM \
  -derivedDataPath build/dd-gate-rel ONLY_ACTIVE_ARCH=YES build > build/gate-rel.log 2>&1
rc=$?; echo "release build: exit $rc"; (( rc == 0 )) || FAILED+=(release)
grep -E "error:" build/gate-rel.log | sort -u | head -10
# The app builds with zero warnings from our code; the framework's and xcodebuild's own don't count.
WARN=$(grep "warning:" build/gate-rel.log | grep -v "Vendor\|ghostty\|xcodebuild" | sort -u)
if [[ -n $WARN ]]; then print -r -- "$WARN" | head -10; FAILED+=(warnings); fi

scripts/check-brand.sh || FAILED+=(brand)

# The failure lines are printed above; the logs go somewhere safe before build/ goes.
if (( $#FAILED )); then
  KEEP=$(mktemp -d "${TMPDIR:-/tmp}/pteron-gate.XXXXXX") && cp build/gate-test.log build/gate-rel.log build/gate-RexKit.log build/gate-RexGlance.log $KEEP/ 2>/dev/null
fi
cleanup
if (( $#FAILED )); then
  echo "gate failed: ${FAILED[*]}${KEEP:+ (logs in $KEEP)}"
  exit 1
fi
echo "gate passed"
