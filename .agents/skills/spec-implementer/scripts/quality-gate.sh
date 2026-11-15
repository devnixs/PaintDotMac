#!/usr/bin/env bash
# PaintDotMac quality gate: the one command that decides whether the app is "green".
#
# Usage (from anywhere inside the repo):
#   quality-gate.sh [--incremental] [--allow-skips] [--sanitizers] [--release]
#
# HEADLESS ONLY (AGENTS.md "Headless testing"): the gate never launches the app, never runs UI
# tests, and never opens a window, so it can run while the user works on something else, and a
# crash can't leave windows behind.
#
# Default run (required after every spec):
#   1. xcodegen generate (when project.yml exists).
#   2. Architecture checks: Core/ never imports AppKit, SwiftUI, Cocoa, or UIKit.
#      Headless checks: project.yml declares no UI test target, no UI test sources exist, and the
#      test sources contain no UI-test, app-launching, or window-showing calls.
#   3. CLEAN Debug build. Fails on any compiler warning in our own sources, because an
#      incremental build hides warnings in files it didn't recompile.
#   4. The headless test target only (-only-testing:PaintDotMacTests): unit, golden-image, and
#      integration tests, hosted in the app in its windowless test-host mode. Fails if any test
#      fails, if no tests ran, if any test was skipped (unless --allow-skips), or if a crash
#      report for the app was written during the run.
#
# Options:
#   --incremental   Skip the clean (faster while iterating; the final run must not use it).
#   --allow-skips   Don't fail on skipped tests (each skip is still listed).
#   --sanitizers    Also run the unit tests under Address + Undefined Behavior Sanitizer, then
#                   under Thread Sanitizer (end of every batch; slow).
#   --release       Also make a clean Release build, verify its signature, and copy it to
#                   build/PaintDotMac.app (end of every batch). The Release app is not launched.
#
# Names can be overridden with environment variables: SCHEME (PaintDotMac), UNIT_TARGET
# (PaintDotMacTests), CORE_DIR (PaintDotMac/Core).
# Logs and result bundles land in build/gate/ (git-ignored). Exit code 0 means green.
set -euo pipefail

die() { echo "gate: FAILED: $*" >&2; exit 1; }
log() { echo; echo "==> $*"; }

INCREMENTAL=0 ALLOW_SKIPS=0 SANITIZERS=0 RELEASE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --incremental) INCREMENTAL=1; shift ;;
    --allow-skips) ALLOW_SKIPS=1; shift ;;
    --sanitizers) SANITIZERS=1; shift ;;
    --release) RELEASE=1; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    --skip-ui|--smoke-seconds) die "$1 was removed: the gate is headless and never runs UI tests or launches the app" ;;
    *) die "unknown argument: $1" ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"
SCHEME="${SCHEME:-PaintDotMac}"
UNIT_TARGET="${UNIT_TARGET:-PaintDotMacTests}"
CORE_DIR="${CORE_DIR:-PaintDotMac/Core}"
OUT="$ROOT/build/gate"
DD="$ROOT/build/DerivedData"
DEST="platform=macOS,arch=$(uname -m)"
SUMMARY=()
# Tells the hosted app it is a test host: no activation, no windows (AGENTS.md "Headless testing").
export PAINTDOTMAC_HEADLESS_TESTS=1

for tool in xcodebuild xcrun jq plutil pgrep pkill; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done
rm -rf "$OUT"
mkdir -p "$OUT"

# --- 1. Project generation --------------------------------------------------------------
if [[ -f project.yml ]]; then
  command -v xcodegen >/dev/null || die "project.yml exists but xcodegen is not on PATH (brew install xcodegen)"
  log "xcodegen generate"
  xcodegen generate --quiet
fi
compgen -G "*.xcodeproj" >/dev/null || compgen -G "*.xcworkspace" >/dev/null \
  || die "no Xcode project in $ROOT (the foundation spec creates it)"

# --- 2. Architecture checks -------------------------------------------------------------
log "Architecture checks"
if [[ -d "$CORE_DIR" ]]; then
  BAD_IMPORTS="$(grep -rnE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(AppKit|SwiftUI|Cocoa|UIKit)\b' \
    --include='*.swift' "$CORE_DIR" || true)"
  [[ -z "$BAD_IMPORTS" ]] || die "Core must not import UI frameworks (AGENTS.md rule 1):
$BAD_IMPORTS"
  echo "Core imports: OK"
else
  echo "Core imports: skipped ($CORE_DIR does not exist yet)"
fi
DISABLED="$(grep -rnE '\.disabled\(|XCTSkip|withKnownIssue' --include='*.swift' . 2>/dev/null \
  | grep -v '/build/' || true)"
if [[ -n "$DISABLED" ]]; then
  echo "Disabled, skipped, or known-issue tests in the sources (each needs a written reason):"
  echo "$DISABLED"
fi

log "Headless checks"
if [[ -f project.yml ]] && grep -nE 'bundle\.ui-testing|UITests' project.yml; then
  die "project.yml declares a UI test target. Tests must be headless (AGENTS.md \"Headless testing\")."
fi
if compgen -G "*UITests" >/dev/null; then
  die "a UI test directory exists ($(compgen -G '*UITests' | tr '\n' ' ')). Tests must be headless."
fi
TEST_DIRS=()
for d in "$UNIT_TARGET" PaintDotMacBenchmarks; do [[ -d "$d" ]] && TEST_DIRS+=("$d"); done
if [[ ${#TEST_DIRS[@]} -gt 0 ]]; then
  # Calls that launch the app, drive the real mouse/keyboard, put a window, sheet, or alert on
  # screen, or touch the user's clipboard or preferences. Support/Headless* (the helpers that
  # assert no window is visible) is exempt.
  NOT_HEADLESS="$(grep -rnE '\b(XCUIApplication|XCUIElement|XCUIDevice)\b|import[[:space:]]+XCUIAutomation|\.showWindow\(|makeKeyAndOrderFront|\.orderFront(Regardless)?\(|\.showWindows\(\)|\.runModal\(|beginSheet(Modal)?\(|\.presentError\(|\.begin\(completionHandler|NSWorkspace\.shared\.open|NSPasteboard\.general|UserDefaults\.standard\.set|/usr/bin/open|PaintDotMac\.app/Contents/MacOS|-UITest[A-Za-z]+' \
    --include='*.swift' "${TEST_DIRS[@]}" | grep -v '/Support/Headless' || true)"
  [[ -z "$NOT_HEADLESS" ]] || die "test sources launch the app or show UI (tests must be headless, AGENTS.md \"Headless testing\"):
$NOT_HEADLESS"
  echo "Test sources: headless"
fi
if [[ -d PaintDotMac ]]; then
  HOOKS="$(grep -rnE '"-UITest[A-Za-z]+"' --include='*.swift' PaintDotMac || true)"
  [[ -z "$HOOKS" ]] || die "app sources still define -UITest* launch hooks (inject test configuration in-process instead):
$HOOKS"
fi

# --- 3. Debug build ---------------------------------------------------------------------
xcb() { xcodebuild -scheme "$SCHEME" -destination "$DEST" "$@"; }

check_warnings() {  # $1 = build log
  local warnings
  warnings="$(grep -E '^/[^:]+\.(swift|metal|h|m|mm|c):[0-9]+(:[0-9]+)?: warning:' "$1" \
    | grep -v '/DerivedData/' | sort -u || true)"
  [[ -z "$warnings" ]] || die "compiler warnings in our sources (fix them, don't silence them):
$warnings"
}

ACTIONS=(build)
[[ $INCREMENTAL == 1 ]] || ACTIONS=(clean build)
log "Debug build (${ACTIONS[*]})"
xcb -configuration Debug -derivedDataPath "$DD" "${ACTIONS[@]}" > "$OUT/build-debug.log" 2>&1 \
  || { grep -E 'error:' "$OUT/build-debug.log" | sort -u | head -40; die "Debug build failed (log: $OUT/build-debug.log)"; }
if [[ $INCREMENTAL == 0 ]]; then check_warnings "$OUT/build-debug.log"; echo "No compiler warnings."; fi
APP="$DD/Build/Products/Debug/$SCHEME.app"
[[ -d "$APP" ]] || die "built app not found at $APP"

# --- 4. Headless tests ------------------------------------------------------------------
# Prints "total passed failed skipped" for a result bundle, and fails the gate on bad results.
summarize() {  # $1 = xcresult, $2 = label
  local json="$OUT/$2-summary.json" tests="$OUT/$2-tests.json"
  xcrun xcresulttool get test-results summary --path "$1" > "$json" 2>/dev/null \
    || die "$2: could not read the test results ($1)"
  local result total passed failed skipped
  result="$(jq -r '.result' "$json")"
  total="$(jq -r '.totalTestCount' "$json")"
  passed="$(jq -r '.passedTests' "$json")"
  failed="$(jq -r '.failedTests' "$json")"
  skipped="$(jq -r '.skippedTests' "$json")"
  local line="$2: $passed passed, $failed failed, $skipped skipped (of $total)"
  echo "$line"
  SUMMARY+=("$line")
  xcrun xcresulttool get test-results tests --path "$1" > "$tests" 2>/dev/null || true
  if [[ "$failed" != 0 || "$result" == "Failed" ]]; then
    jq -r '.testFailures[]? | "  ✗ \(.testIdentifierString // .testName): \(.failureText)"' "$json" | head -40
    die "$2: tests failed"
  fi
  (( total > 0 )) || die "$2: no tests ran"
  if [[ "$skipped" != 0 ]]; then
    jq -r '.. | objects | select(.result? == "Skipped" and .nodeType? == "Test Case") | "  - skipped: \(.nodeIdentifier // .name)"' \
      "$tests" 2>/dev/null | head -40 || true
    [[ $ALLOW_SKIPS == 1 ]] || die "$2: $skipped skipped test(s). Make them run, or rerun with --allow-skips and justify each one."
  fi
}

APP_EXE_NAME="$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist" 2>/dev/null || echo "$SCHEME")"
# A crashed test host must not linger. Kill only processes started from our build directories.
kill_test_hosts() { pkill -f "^$ROOT/build/DerivedData[^ ]*/$SCHEME\.app/" 2>/dev/null || true; }
trap kill_test_hosts EXIT

crash_reports_since() {  # $1 = marker file
  find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -newer "$1" \
    \( -name "$APP_EXE_NAME-*" -o -name "${APP_EXE_NAME}_*" -o -name "xctest-*" \) 2>/dev/null || true
}

run_tests() {  # $1 = label, $2 = derived data, $3.. = extra xcodebuild arguments
  local label="$1" dd="$2"; shift 2
  local marker="$OUT/crash-marker-$label" crashes
  touch "$marker"; sleep 1  # crash reports must be strictly newer than the marker
  kill_test_hosts
  xcb -derivedDataPath "$dd" -resultBundlePath "$OUT/$label.xcresult" -only-testing:"$UNIT_TARGET" \
    "$@" test > "$OUT/$label.log" 2>&1 || true   # the result bundle decides, not the exit code alone
  kill_test_hosts
  [[ -d "$OUT/$label.xcresult" ]] || { tail -40 "$OUT/$label.log"; die "$label: no result bundle (log: $OUT/$label.log)"; }
  summarize "$OUT/$label.xcresult" "$label"
  crashes="$(crash_reports_since "$marker")"
  if [[ -n "$crashes" ]]; then
    echo "$crashes"
    head -60 "$(echo "$crashes" | head -1)" || true
    die "$label: crash report(s) written during the test run"
  fi
}

log "Headless tests (Debug, $UNIT_TARGET only; no UI tests, no app launch)"
run_tests tests "$DD"
grep -q '\*\* TEST SUCCEEDED \*\*' "$OUT/tests.log" || { tail -40 "$OUT/tests.log"; die "xcodebuild did not report TEST SUCCEEDED (log: $OUT/tests.log)"; }
SUMMARY+=("tests: no crash reports during the run")

# --- Optional: sanitizers ---------------------------------------------------------------
# Some macOS + Xcode combinations ship a sanitizer runtime that hangs or crashes while it starts,
# before any of our code runs (seen on macOS 26.6 with Xcode 26.3). The hosted test run then
# "hangs before establishing connection" for minutes. Probe each sanitizer with a trivial program
# first, and report an unusable one as UNAVAILABLE instead of hanging or passing silently.
sanitizer_works() {  # $1 = clang -fsanitize value
  local dir="$OUT/probe-$1"
  mkdir -p "$dir"
  printf 'int main(void) { return 0; }\n' > "$dir/probe.c"
  xcrun clang -fsanitize="$1" "$dir/probe.c" -o "$dir/probe" > "$dir/build.log" 2>&1 || return 1
  ( perl -e 'alarm shift; exec @ARGV' 20 "$dir/probe" > "$dir/run.log" 2>&1 ) 2>/dev/null
}

UNAVAILABLE=()
if [[ $SANITIZERS == 1 ]]; then
  if sanitizer_works address,undefined; then
    log "Unit tests under Address + Undefined Behavior Sanitizer"
    run_tests asan "$ROOT/build/DerivedData-asan" -enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES
    ! grep -qE 'ERROR: AddressSanitizer|runtime error:' "$OUT/asan.log" \
      || { grep -E -A20 'ERROR: AddressSanitizer|runtime error:' "$OUT/asan.log" | head -60; die "sanitizer reported errors"; }
  else
    UNAVAILABLE+=("Address + Undefined Behavior Sanitizer")
  fi

  if sanitizer_works thread; then
    log "Unit tests under Thread Sanitizer"
    run_tests tsan "$ROOT/build/DerivedData-tsan" -enableThreadSanitizer YES
    ! grep -q 'WARNING: ThreadSanitizer' "$OUT/tsan.log" \
      || { grep -A20 'WARNING: ThreadSanitizer' "$OUT/tsan.log" | head -60; die "Thread Sanitizer reported data races"; }
  else
    UNAVAILABLE+=("Thread Sanitizer")
  fi
  for s in ${UNAVAILABLE[@]+"${UNAVAILABLE[@]}"}; do
    echo "WARNING: $s is UNAVAILABLE on this Mac: a trivial program built with it hangs or crashes (see $OUT/probe-*)."
    SUMMARY+=("$s: UNAVAILABLE on this Mac (toolchain/OS problem, not our code); NOT RUN")
  done
fi

# --- Optional: Release build ------------------------------------------------------------
if [[ $RELEASE == 1 ]]; then
  log "Release build (clean)"
  RDD="$ROOT/build/DerivedData-release"
  xcb -configuration Release -derivedDataPath "$RDD" clean build > "$OUT/build-release.log" 2>&1 \
    || { grep -E 'error:' "$OUT/build-release.log" | sort -u | head -40; die "Release build failed (log: $OUT/build-release.log)"; }
  check_warnings "$OUT/build-release.log"
  RAPP="$RDD/Build/Products/Release/$SCHEME.app"
  [[ -d "$RAPP" ]] || die "Release app not found at $RAPP"
  codesign --verify --deep --strict "$RAPP" 2>/dev/null || die "Release app fails codesign verification"
  rm -rf "$ROOT/build/$SCHEME.app"
  ditto "$RAPP" "$ROOT/build/$SCHEME.app"
  SUMMARY+=("Release app: $ROOT/build/$SCHEME.app")
fi

log "GREEN"
printf '%s\n' "${SUMMARY[@]}"
