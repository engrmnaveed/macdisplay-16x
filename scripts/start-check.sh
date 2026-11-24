#!/bin/zsh
# Starts the packaged app for a few seconds and fails if it does not stay up. The unit tests
# run on fakes and the command line tool never starts the app, so this is the check that
# catches a crash at start, such as the first v0.4 build's.
#
#   scripts/start-check.sh [APP]        APP is dist/Display 16X.app unless given
#
# The app runs in safe mode, so it restores and reapplies nothing, with a settings folder of
# its own in a temporary folder (DISPLAY16X_SUPPORT_DIRECTORY), so the settings of a copy in
# daily use are never read or written. It reads the displays as at every start, a monitor
# over DDC too, and writes nothing to them. It has to answer on its own socket, say it is in
# safe mode, still run 5 seconds later and answer again, then quit cleanly on SIGTERM.
#
# A copy of Display 16X that is already running is never touched. A build with a folder of
# its own refuses to start next to one, so the check is skipped then, and says so. On CI,
# where no copy runs, a skip is a failure.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP="${1:-dist/Display 16X.app}"
APP="${APP:A}"
EXE="$APP/Contents/MacOS/Display 16X"
TOOL="$APP/Contents/MacOS/display16x"
ANSWER_WITHIN=15
STAY_UP=5
QUIT_WITHIN=10
REPORTS="$HOME/Library/Logs/DiagnosticReports"

fail() {
    print -u2 "start check: $1"
    exit 1
}

[[ -x "$EXE" && -x "$TOOL" ]] || fail "$APP has no app or no command line tool. Run scripts/package-macos.sh first"

if pgrep -x -U "$(id -u)" "Display 16X" >/dev/null; then
    [[ -z "${CI:-}" ]] || fail "a copy of Display 16X is already running on this CI runner, so the app cannot be started"
    print "Start check skipped: Display 16X is running on this Mac, and a build with a settings folder of its own does not start next to it. CI runs this check."
    exit 0
fi

SUPPORT="$(mktemp -d "${TMPDIR:-/tmp}/display16x-start.XXXXXX")"
LOG="$SUPPORT/app.log"
PID=""
cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -KILL "$PID" 2>/dev/null || true
    fi
    rm -rf "$SUPPORT"
}
trap cleanup EXIT

# Says how the app ended, with its log and any crash report, and fails.
ended() {
    local code=0
    wait "$PID" || code=$?
    PID=""
    local how="with status $code"
    (( code > 128 )) && how="on signal $(( code - 128 )) ($(kill -l $(( code - 128 )) 2>/dev/null || print unknown))"
    print -u2 "start check: the app ended $how $1. Its log:"
    tail -n 40 "$LOG" >&2 || true
    # macOS writes the crash report a moment after the process ends.
    local report="" try
    for try in {1..10}; do
        report="$(find "$REPORTS" -maxdepth 1 -name 'Display 16X*' -newer "$SUPPORT/started" 2>/dev/null | head -n 1)"
        [[ -n "$report" ]] && break
        sleep 0.5
    done
    if [[ -n "$report" ]]; then
        print -u2 "Crash report: $report"
        head -c 6000 "$report" >&2 || true
        print -u2 ""
    fi
    fail "the app did not stay up"
}

export DISPLAY16X_SUPPORT_DIRECTORY="$SUPPORT"
touch "$SUPPORT/started"
"$EXE" --safe --verbose >"$LOG" 2>&1 &
PID=$!

answer=""
for _ in {1..$(( ANSWER_WITHIN * 2 ))}; do
    kill -0 "$PID" 2>/dev/null || ended "before it answered"
    if answer="$("$TOOL" status --timeout 1 2>/dev/null)"; then
        break
    fi
    answer=""
    sleep 0.5
done
[[ -n "$answer" ]] || { tail -n 40 "$LOG" >&2 || true; fail "the app did not answer within $ANSWER_WITHIN seconds"; }
[[ "$answer" == *"safe mode: on"* ]] || fail "the app answered, but not in safe mode: $answer"

sleep "$STAY_UP"
kill -0 "$PID" 2>/dev/null || ended "within $STAY_UP seconds of answering"
"$TOOL" status --timeout 2 >/dev/null 2>&1 || fail "the app is running but stopped answering"

kill -TERM "$PID"
for _ in {1..$(( QUIT_WITHIN * 2 ))}; do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.5
done
kill -0 "$PID" 2>/dev/null && fail "the app did not quit within $QUIT_WITHIN seconds of SIGTERM"
code=0
wait "$PID" || code=$?
PID=""
(( code == 0 )) || { tail -n 40 "$LOG" >&2 || true; fail "the app quit with status $code on SIGTERM"; }

print "App: started in safe mode with a settings folder of its own, answered, still ran ${STAY_UP} seconds later, and quit cleanly."
