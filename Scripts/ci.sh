#!/bin/zsh
# Local CI: build + unit tests on macOS, then the Foundation Models tests on the iOS 27 simulator.
# Needs Xcode 27 and, for the live tests, an SCX key in ~/.config/scx/api_key.
# Set DEVELOPER_DIR if Xcode 27 is not the selected toolchain.
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
cd "$(dirname "$0")/.."

# On Xcode 26 and older the provider compiles out and the simulator suite runs zero tests, which
# would otherwise look like a pass. Fail fast instead.
XCODE_MAJOR=$(DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -version | awk 'NR==1{split($2,v,"."); print v[1]}')
if [ "${XCODE_MAJOR:-0}" -lt 27 ]; then
    echo "Xcode 27 or newer is required, found ${XCODE_MAJOR:-unknown} at $DEVELOPER_DIR."
    echo "Set DEVELOPER_DIR to your Xcode 27, for example:"
    echo "  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/ci.sh"
    exit 1
fi

swift build
swift test --filter SCXRuntimeTests

# Some toolchains hang after Swift Testing finishes, so watch the log for the summary line and stop it.
LOG=.build/ci-sim.log
DESTINATION=${SCX_CI_DESTINATION:-platform=iOS Simulator,OS=27.0,name=iPhone 18 Pro Max}
xcodebuild test -scheme SCXSwiftKit-Package -only-testing:SCXSwiftKitTests \
    -destination "$DESTINATION" \
    -derivedDataPath .build/dd > "$LOG" 2>&1 &
XCB=$!
for _ in $(seq 1 120); do
    grep -q "Test run with" "$LOG" 2>/dev/null && break
    kill -0 $XCB 2>/dev/null || break
    sleep 5
done
kill $XCB 2>/dev/null || true

grep -E "✔|✘" "$LOG" || { echo "--- no test results, log tail:"; tail -40 "$LOG"; exit 1; }
if grep -q "✘" "$LOG"; then exit 1; fi
# A test that hangs leaves passes in the log but no summary; require the suite to actually finish.
grep -q "Test run with" "$LOG" || { echo "--- suite never finished (watchdog kill), log tail:"; tail -40 "$LOG"; exit 1; }
echo "CI green"
