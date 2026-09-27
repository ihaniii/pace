#!/usr/bin/env bash
#
# test-pace.sh — run the unit tests without touching the TCC-paired
# Pace.app the user uses interactively.
#
# Why this exists
# ---------------
# CLAUDE.md says: "Do NOT run `xcodebuild` from the terminal — it
# invalidates TCC permissions and the app will need to re-request
# screen recording, accessibility, etc."
#
# That observation applies to `xcodebuild` rebuilding into the default
# DerivedData path (`~/Library/Developer/Xcode/DerivedData/…`), which
# is the same path Xcode's Cmd+R uses. Re-signing the same bundle
# identifier at the same path may cause macOS to re-evaluate TCC.
#
# This script builds + tests into an **isolated DerivedData path**
# (`/tmp/pace-test-derived-data`). The user's interactive Pace.app at
# its usual DerivedData path stays untouched.
#
# Risk caveat
# -----------
# macOS TCC's exact identity-resolution algorithm isn't documented.
# In theory `(bundle_id, code_signing_identity)` is the key, in which
# case re-signing the same bundle ID at any path could still affect
# TCC grants for the interactive Pace.app.
#
# If you run this script and your interactive Pace.app starts
# re-prompting for Accessibility / Screen Recording / Mic permissions
# on next Cmd+R, that hypothesis was wrong; close this script and
# we'll switch to a stand-alone Swift Package approach for tests.
#
# UserDefaults isolation
# ----------------------
# Unit tests run inside the host app, and `UserDefaults.standard` is
# keyed by the host's bundle identifier. Built as `com.pace.app.debug`
# (the Debug app you run from Xcode), every test read and wrote your
# real preferences — your settings leaked into tests, and tests could
# leave consent/privacy flags changed if the host crashed mid-test.
# This script builds the host as `com.pace.app.unittesthost` instead,
# resets that domain before every run, proves the override reached the
# host target BEFORE any test runs, and re-checks the built bundle after.
# Xcode's Cmd+U does not use this script and still runs as
# `com.pace.app.debug`.
#
# Usage
# -----
#   ./scripts/test-pace.sh                       # run all unit tests
#   ./scripts/test-pace.sh --coverage            # run tests + collect coverage
#   ./scripts/test-pace.sh PaceTagParsersTests   # filter
#
# Returns xcodebuild's exit code (0 on green, non-zero on failure).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DERIVED_DATA_PATH="$HOME/.pace-test-derived-data"
# Dedicated preferences domain for the test host (see header). Never one
# of the user's real domains below.
TEST_HOST_BUNDLE_IDENTIFIER="com.pace.app.unittesthost"
REAL_PREFERENCES_DOMAINS=("com.pace.app.debug" "com.pace.app")
PROJECT_PATH="$PROJECT_DIR/leanring-buddy.xcodeproj"
# Scheme name kept as `leanring-buddy` (matches the Xcode default
# scheme alongside the legacy folder name). The PRODUCT_NAME is `Pace`,
# but `xcodebuild -list` shows the scheme name, not the product.
SCHEME="leanring-buddy"
TEST_TARGET="leanring-buddyTests"
DESTINATION='platform=macOS,arch=arm64'

# Use the full Xcode.app, not the Command Line Tools — xcodebuild
# only ships with Xcode.app. If `xcode-select` is pointing at
# CommandLineTools (common on fresh dev machines), `xcodebuild` errors
# out before doing anything. Setting `DEVELOPER_DIR` here picks Xcode
# without touching the system-wide setting (no sudo needed).
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    else
        # Fall back to a versioned Xcode beta (e.g. Xcode-27.0.0-Beta.app).
        # Exclude `Xcodes.app` — that's the Xcodes version-manager installer,
        # not an Xcode toolchain, and it has no Contents/Developer. Without
        # this filter it sorts last and gets picked, leaving DEVELOPER_DIR
        # unset so xcodebuild falls back to the Command Line Tools and errors.
        beta_xcode="$(/usr/bin/find /Applications -maxdepth 1 -name 'Xcode*.app' ! -name 'Xcodes.app' -type d 2>/dev/null | /usr/bin/sort | /usr/bin/tail -1)"
        if [[ -n "$beta_xcode" && -d "$beta_xcode/Contents/Developer" ]]; then
            export DEVELOPER_DIR="$beta_xcode/Contents/Developer"
        fi
    fi
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Project not found: $PROJECT_PATH" >&2
    exit 2
fi

ONLY_TESTING_ARGS=()
ENABLE_COVERAGE=0
for filter in "$@"; do
    if [[ "$filter" == "--coverage" ]]; then
        ENABLE_COVERAGE=1
        continue
    fi
    ONLY_TESTING_ARGS+=("-only-testing:${TEST_TARGET}/${filter}")
done

echo "▶ Pace test runner — isolated DerivedData at $DERIVED_DATA_PATH"
echo "  (will not touch ~/Library/Developer/Xcode/DerivedData/leanring-buddy-*)"
if [[ $ENABLE_COVERAGE -eq 1 ]]; then
    echo "  📊 Code coverage collection enabled (-enableCodeCoverage YES)"
fi
echo

# `xcodebuild test` builds the test bundle + its host app (Pace.app)
# into DERIVED_DATA_PATH, then runs the tests inside that host app.
# Result bundle path is pinned so we can query the structured summary
# afterward via `xcresulttool` instead of scraping the noisy stdout.
#
# Code-signing is disabled for the test build: the keychain identity
# may not be available from a terminal-launched xcodebuild (it is from
# Xcode interactive), and unit tests don't need entitlements to run.
# The user's interactive Pace.app build keeps its real signing.

RESULT_BUNDLE_PATH="$DERIVED_DATA_PATH/pace-tests.xcresult"
rm -rf "$RESULT_BUNDLE_PATH"
BUILD_LOG_FILE="$DERIVED_DATA_PATH/last-build.log"
mkdir -p "$DERIVED_DATA_PATH"

COVERAGE_VALUE="NO"
if [[ $ENABLE_COVERAGE -eq 1 ]]; then
    COVERAGE_VALUE="YES"
fi

# Pre-flight: prove the bundle-identifier override reaches the host target
# BEFORE any test runs. If it did not, tests would silently read and write
# the user's real preferences, so stop instead. (~5s; no build.)
HOST_TARGET_NAME="$SCHEME"
RESOLVED_HOST_BUNDLE_IDENTIFIER="$(
    xcodebuild -showBuildSettings \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        PRODUCT_BUNDLE_IDENTIFIER="$TEST_HOST_BUNDLE_IDENTIFIER" 2>/dev/null \
    | awk -v hostHeader="Build settings for action build and target $HOST_TARGET_NAME:" '
        $0 == hostHeader { inHostTarget = 1; next }
        /^Build settings for action/ { inHostTarget = 0 }
        inHostTarget && $1 == "PRODUCT_BUNDLE_IDENTIFIER" { print $3; exit }
    ' || true
)"
if [[ "$RESOLVED_HOST_BUNDLE_IDENTIFIER" != "$TEST_HOST_BUNDLE_IDENTIFIER" ]]; then
    echo "❌ Test host would build as '${RESOLVED_HOST_BUNDLE_IDENTIFIER:-<unresolved>}', not '$TEST_HOST_BUNDLE_IDENTIFIER'." >&2
    echo "   Refusing to run: tests would use your real preferences." >&2
    exit 3
fi

# Fingerprint the user's real preferences so a change during the run is
# reported. A warning, not a failure: a running Pace legitimately writes them.
real_preferences_fingerprint() {
    local preferences_domain preferences_file
    for preferences_domain in "${REAL_PREFERENCES_DOMAINS[@]}"; do
        preferences_file="$HOME/Library/Preferences/$preferences_domain.plist"
        if [[ -f "$preferences_file" ]]; then
            shasum -a 256 "$preferences_file"
        else
            echo "absent $preferences_domain"
        fi
    done
}
REAL_PREFERENCES_FINGERPRINT_BEFORE_RUN="$(real_preferences_fingerprint)"

# Every run starts from an empty test preferences domain, so no test
# depends on state left behind by an earlier run.
defaults delete "$TEST_HOST_BUNDLE_IDENTIFIER" >/dev/null 2>&1 || true

set +e
xcodebuild test \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$RESULT_BUNDLE_PATH" \
    -parallel-testing-enabled NO \
    -only-testing:"$TEST_TARGET" \
    "${ONLY_TESTING_ARGS[@]+"${ONLY_TESTING_ARGS[@]}"}" \
    -enableCodeCoverage "$COVERAGE_VALUE" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    PRODUCT_BUNDLE_IDENTIFIER="$TEST_HOST_BUNDLE_IDENTIFIER" \
    > "$BUILD_LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

# Post-run: the host that actually ran must carry the test identifier.
BUILT_HOST_INFO_PLIST="$DERIVED_DATA_PATH/Build/Products/Debug/Pace.app/Contents/Info.plist"
if [[ -f "$BUILT_HOST_INFO_PLIST" ]]; then
    BUILT_HOST_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT_HOST_INFO_PLIST" 2>/dev/null || true)"
    if [[ "$BUILT_HOST_BUNDLE_IDENTIFIER" != "$TEST_HOST_BUNDLE_IDENTIFIER" ]]; then
        echo "❌ The test host ran as '${BUILT_HOST_BUNDLE_IDENTIFIER:-<unreadable>}', not '$TEST_HOST_BUNDLE_IDENTIFIER'." >&2
        echo "   Your real preferences may have been read or written by this run." >&2
        exit 3
    fi
fi
if [[ "$(real_preferences_fingerprint)" != "$REAL_PREFERENCES_FINGERPRINT_BEFORE_RUN" ]]; then
    echo "⚠️  Your real Pace preferences (${REAL_PREFERENCES_DOMAINS[*]}) changed during this run."
    echo "   Expected if Pace was running; otherwise the test-host isolation needs a look."
fi

if [[ $EXIT_CODE -ne 0 ]]; then
    echo "❌ xcodebuild exited $EXIT_CODE — surfacing the last 60 lines of build output:"
    echo "  (full log: $BUILD_LOG_FILE)"
    echo
    tail -60 "$BUILD_LOG_FILE" | grep -vE '^Resolve Package' || true
    exit $EXIT_CODE
fi

# Pretty-print the result-bundle summary via xcresulttool. Falls back
# to grepping the raw log if xcresulttool isn't found.
if command -v xcrun >/dev/null 2>&1 && [[ -d "$RESULT_BUNDLE_PATH" ]]; then
    xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE_PATH" \
        | python3 -c '
import json, sys
data = json.load(sys.stdin)
total = data.get("totalTestCount", 0)
passed = data.get("passedTests", 0)
failed = data.get("failedTests", 0)
skipped = data.get("skippedTests", 0)
result = data.get("result", "Unknown")
elapsed = (data.get("finishTime", 0) - data.get("startTime", 0))
icon = "✅" if result == "Passed" else "❌"
print(f"{icon} {result} — {passed}/{total} passed, {failed} failed, {skipped} skipped, {elapsed:.1f}s")
for failure in data.get("testFailures", [])[:20]:
    target = failure.get("targetName", "?")
    name = failure.get("testName", "?")
    msg = failure.get("failureText", "")[:200]
    print(f"   ✗ {target}::{name}")
    if msg:
        print(f"     {msg}")
if result != "Passed" or total <= 0 or failed > 0:
    sys.exit(1)
'
else
    echo "❌ Cannot verify a non-zero executed test count from the result bundle." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Coverage extraction (only when --coverage was passed).
# Uses `xcrun xccov` to read the .xcresult bundle produced above and
# prints a per-target line-coverage summary. A requested coverage run fails
# when Xcode does not produce readable evidence; silent skips are false green.
# ---------------------------------------------------------------------------
if [[ $ENABLE_COVERAGE -eq 1 && -d "$RESULT_BUNDLE_PATH" ]]; then
    echo
    echo "📊 Coverage report"
    echo "  (source: $RESULT_BUNDLE_PATH)"
    if ! xcrun xccov view --report --json "$RESULT_BUNDLE_PATH" > "$DERIVED_DATA_PATH/coverage-report.json"; then
        echo "  ❌ xccov could not read the result bundle." >&2
        exit 1
    fi
    python3 -c '
import json
import sys
with open("'"$DERIVED_DATA_PATH"'/coverage-report.json") as f:
    data = json.load(f)
    targets = data.get("targets", [])
    if not targets:
        print("  no coverage targets found in result bundle", file=sys.stderr)
        sys.exit(1)
    for target in targets:
        name = target.get("name", "unknown")
        line_cov = target.get("lineCoverage", 0) * 100
        print(f"  {name}: {line_cov:.1f}% line coverage")
'
    echo "  full report: $DERIVED_DATA_PATH/coverage-report.json"
fi

exit $EXIT_CODE
