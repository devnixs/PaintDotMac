#!/usr/bin/env bash
# PaintDotMac quality gate: the one command that decides whether the app is "green".
#
# Usage (from anywhere inside the repo):
#   quality-gate.sh [--incremental] [--skip-ui] [--allow-skips] [--sanitizers] [--release]
#                   [--smoke-seconds N]
#
# Default run (required after every spec):
#   1. xcodegen generate (when project.yml exists).
#   2. Architecture checks: Core/ never imports AppKit, SwiftUI, Cocoa, or UIKit.
#   3. CLEAN Debug build. Fails on any compiler warning in our own sources, because an
#      incremental build hides warnings in files it didn't recompile.
#   4. Every test in the scheme: unit, golden-image, integration, and XCUITest UI tests.
#      Fails if any test fails, if no tests ran, if any test was skipped (unless
#      --allow-skips), or if the UI test target didn't run (unless --skip-ui).
#   5. Launch smoke test of the Debug app: launched empty, with a PNG, and with a JPEG. Each
#      launch must stay alive for --smoke-seconds (default 8) and leave no crash report.
#
# Options:
#   --incremental   Skip the clean (faster while iterating; the final run must not use it).
#   --skip-ui       Skip the UI test target (only before the foundation spec creates it, or
#                   when the user has said UI tests can't run on this Mac). Always reported.
#   --allow-skips   Don't fail on skipped tests (each skip is still listed).
#   --sanitizers    Also run the unit tests under Address + Undefined Behavior Sanitizer, then
#                   under Thread Sanitizer (end of every batch; slow).
#   --release       Also make a clean Release build, smoke test it, and copy it to
#                   build/PaintDotMac.app (end of every batch).
#
# Names can be overridden with environment variables: SCHEME (PaintDotMac), UNIT_TARGET
# (PaintDotMacTests), UI_TARGET (PaintDotMacUITests), CORE_DIR (PaintDotMac/Core).
# Logs and result bundles land in build/gate/ (git-ignored). Exit code 0 means green.
set -euo pipefail

die() { echo "gate: FAILED: $*" >&2; exit 1; }
log() { echo; echo "==> $*"; }

INCREMENTAL=0 SKIP_UI=0 ALLOW_SKIPS=0 SANITIZERS=0 RELEASE=0 SMOKE_SECONDS=8
while [[ $# -gt 0 ]]; do
  case "$1" in
    --incremental) INCREMENTAL=1; shift ;;
    --skip-ui) SKIP_UI=1; shift ;;
    --allow-skips) ALLOW_SKIPS=1; shift ;;
    --sanitizers) SANITIZERS=1; shift ;;
    --release) RELEASE=1; shift ;;
    --smoke-seconds) SMOKE_SECONDS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$SMOKE_SECONDS" =~ ^[0-9]+$ ]] || die "--smoke-seconds needs a number"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"
SCHEME="${SCHEME:-PaintDotMac}"
UNIT_TARGET="${UNIT_TARGET:-PaintDotMacTests}"
UI_TARGET="${UI_TARGET:-PaintDotMacUITests}"
CORE_DIR="${CORE_DIR:-PaintDotMac/Core}"
OUT="$ROOT/build/gate"
DD="$ROOT/build/DerivedData"
DEST="platform=macOS,arch=$(uname -m)"
SUMMARY=()

for tool in xcodebuild xcrun jq plutil sips open pgrep; do
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

# --- 4. Tests ---------------------------------------------------------------------------
# Prints "total passed failed skipped" for a result bundle, and fails the gate on bad results.
summarize() {  # $1 = xcresult, $2 = label, $3 = require UI target (0/1)
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
  if [[ "$3" == 1 ]]; then
    jq -e --arg t "$UI_TARGET" '[.. | objects | select(.name? == $t)] | length > 0' "$tests" >/dev/null 2>&1 \
      || die "$2: the UI test target $UI_TARGET did not run (add it to the scheme, or pass --skip-ui with a reason)"
  fi
}

TEST_ARGS=()
REQUIRE_UI=1
if [[ $SKIP_UI == 1 ]]; then TEST_ARGS+=("-skip-testing:$UI_TARGET"); REQUIRE_UI=0; SUMMARY+=("UI tests: SKIPPED (--skip-ui)"); fi
log "Tests (Debug)$([[ $SKIP_UI == 1 ]] && echo ', UI tests skipped')"
# UI tests drive the real mouse and keyboard: don't touch the Mac while they run.
xcb -derivedDataPath "$DD" -resultBundlePath "$OUT/tests.xcresult" ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} test \
  > "$OUT/test.log" 2>&1 || true   # the result bundle decides, not xcodebuild's exit code alone
[[ -d "$OUT/tests.xcresult" ]] || { tail -40 "$OUT/test.log"; die "tests did not produce a result bundle (log: $OUT/test.log)"; }
summarize "$OUT/tests.xcresult" tests "$REQUIRE_UI"
grep -q '\*\* TEST SUCCEEDED \*\*' "$OUT/test.log" || { tail -40 "$OUT/test.log"; die "xcodebuild did not report TEST SUCCEEDED (log: $OUT/test.log)"; }

# --- 5. Launch smoke test ---------------------------------------------------------------
make_fixtures() {
  local dir="$OUT/fixtures"
  mkdir -p "$dir"
  # A 1×1 opaque PNG, scaled up with sips into realistic fixtures.
  echo 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==' \
    | base64 -D > "$dir/seed.png"
  sips -z 1200 1600 "$dir/seed.png" --out "$dir/smoke.png" >/dev/null
  sips -s format jpeg "$dir/smoke.png" --out "$dir/smoke.jpg" >/dev/null
  [[ -s "$dir/smoke.png" && -s "$dir/smoke.jpg" ]] || die "could not create smoke fixtures"
}

regex_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }

smoke() {  # $1 = app bundle, $2 = label
  local app="$1" label="$2" exe_name exe pattern marker
  exe_name="$(plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")"
  exe="$app/Contents/MacOS/$exe_name"
  pattern="^$(regex_escape "$exe")( |$)"
  marker="$OUT/smoke-marker-$label"
  touch "$marker"
  sleep 1  # crash reports must be strictly newer than the marker
  local -a cases=("" "$OUT/fixtures/smoke.png" "$OUT/fixtures/smoke.jpg")
  local file pid i name
  for file in "${cases[@]}"; do
    name="${file:+$(basename "$file")}"; name="${name:-no document}"
    pkill -f "$pattern" 2>/dev/null || true
    sleep 1
    local -a open_args=(-n -F -a "$app" --stdout "$OUT/smoke-$label.log" --stderr "$OUT/smoke-$label.log")
    [[ -n "$file" ]] && open_args+=("$file")
    open "${open_args[@]}" --args -ApplePersistenceIgnoreState YES \
      || die "$label smoke ($name): open failed"
    pid=""
    for i in $(seq 1 30); do
      pid="$(pgrep -nf "$pattern" || true)"
      [[ -n "$pid" ]] && break
      sleep 0.5
    done
    [[ -n "$pid" ]] || die "$label smoke ($name): the app never started"
    sleep "$SMOKE_SECONDS"
    if ! kill -0 "$pid" 2>/dev/null; then
      tail -30 "$OUT/smoke-$label.log" 2>/dev/null || true
      die "$label smoke ($name): the app exited or crashed within $SMOKE_SECONDS s"
    fi
    kill -TERM "$pid" 2>/dev/null || true
    for i in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$pid" 2>/dev/null || true
    echo "$label smoke ($name): stayed up ${SMOKE_SECONDS}s"
  done
  local crashes
  crashes="$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -newer "$marker" \
    \( -name "$exe_name-*" -o -name "${exe_name}_*" \) 2>/dev/null || true)"
  if [[ -n "$crashes" ]]; then
    echo "$crashes"
    head -60 "$(echo "$crashes" | head -1)" || true
    die "$label smoke: crash report(s) written during the smoke test"
  fi
  SUMMARY+=("$label launch smoke: OK (empty, PNG, JPEG; ${SMOKE_SECONDS}s each; no crash reports)")
}

log "Launch smoke test (Debug)"
make_fixtures
smoke "$APP" debug

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
    xcb -derivedDataPath "$ROOT/build/DerivedData-asan" -resultBundlePath "$OUT/asan.xcresult" \
      -enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES \
      -only-testing:"$UNIT_TARGET" test > "$OUT/asan.log" 2>&1 || true
    [[ -d "$OUT/asan.xcresult" ]] || { tail -40 "$OUT/asan.log"; die "ASan run produced no result bundle (log: $OUT/asan.log)"; }
    summarize "$OUT/asan.xcresult" asan-ubsan 0
    ! grep -qE 'ERROR: AddressSanitizer|runtime error:' "$OUT/asan.log" \
      || { grep -E -A20 'ERROR: AddressSanitizer|runtime error:' "$OUT/asan.log" | head -60; die "sanitizer reported errors"; }
  else
    UNAVAILABLE+=("Address + Undefined Behavior Sanitizer")
  fi

  if sanitizer_works thread; then
    log "Unit tests under Thread Sanitizer"
    xcb -derivedDataPath "$ROOT/build/DerivedData-tsan" -resultBundlePath "$OUT/tsan.xcresult" \
      -enableThreadSanitizer YES -only-testing:"$UNIT_TARGET" test > "$OUT/tsan.log" 2>&1 || true
    [[ -d "$OUT/tsan.xcresult" ]] || { tail -40 "$OUT/tsan.log"; die "TSan run produced no result bundle (log: $OUT/tsan.log)"; }
    summarize "$OUT/tsan.xcresult" tsan 0
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
  log "Launch smoke test (Release)"
  smoke "$RAPP" release
  rm -rf "$ROOT/build/$SCHEME.app"
  ditto "$RAPP" "$ROOT/build/$SCHEME.app"
  SUMMARY+=("Release app: $ROOT/build/$SCHEME.app")
fi

log "GREEN"
printf '%s\n' "${SUMMARY[@]}"
