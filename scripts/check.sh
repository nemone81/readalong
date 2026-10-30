#!/bin/zsh
# Verifica completa del repo: xcodegen + build + test iOS, poi pytest di
# makebook se presente. Da lanciare dalla root del repo (o da dove si vuole:
# lo script si sposta da solo). Output filtrato: esito e, se fallisce, le
# righe `error:`.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

LOG_DIR="$(mktemp -d -t readalong-check)"
SIM_ID=""

# Pulizia all'uscita, anche in caso di errore o interruzione: il simulatore
# dedicato si spegne e si cancella, i log temporanei pure.
cleanup() {
    if [[ -n "$SIM_ID" ]]; then
        xcrun simctl shutdown "$SIM_ID" >/dev/null 2>&1 || true
        xcrun simctl delete "$SIM_ID" >/dev/null 2>&1 || true
    fi
    rm -rf "$LOG_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
    local step="$1" log="$2"
    print -u2 "FALLITO: $step"
    # Prima le righe di errore del compilatore/test; se non ce ne sono, la coda del log.
    if ! grep -E "error:|\*\* (BUILD|TEST) FAILED|✘|Test .* failed" "$log" | sort -u | head -40 >&2; then
        tail -20 "$log" >&2
    fi
    exit 1
}

# --- Simulatore dedicato: "ReadAlong-<branch>", iPhone 17, creato qui e
# cancellato alla fine (anche se qualcosa fallisce). Due check.sh in parallelo
# (worktree diversi) non si contendono piu' lo stesso simulatore.
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"

# Runtime: il piu' recente iOS 26.x; se non ce n'e', il piu' recente >= 26
# (il deployment target).
pick_runtime() {
    xcrun simctl list runtimes available | awk '
        /^iOS / {
            split($2, v, ".")
            if (v[1] + 0 < 26) next
            id = $NF
            key = sprintf("%03d%03d%03d", v[1], v[2], v[3])
            if (v[1] + 0 == 26 && key > best26) { best26 = key; id26 = id }
            if (key > bestAny) { bestAny = key; idAny = id }
        }
        END { print (id26 != "" ? id26 : idAny) }'
}

# UDID dei simulatori con esattamente questo nome (avanzi di run interrotte).
devices_named() {
    xcrun simctl list devices | awk -v name="$1" '
        {
            line = $0; sub(/^ +/, "", line)
            n = line; sub(/ \([0-9A-F-]{36}\).*$/, "", n)
            if (n == name && match(line, /\([0-9A-F-]{36}\)/)) print substr(line, RSTART + 1, RLENGTH - 2)
        }'
}

RUNTIME="$(pick_runtime)"
if [[ -z "$RUNTIME" ]]; then
    print -u2 "FALLITO: nessun runtime iOS >= 26 installato"
    exit 1
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || print detached)"
SIM_NAME="ReadAlong-${BRANCH//[^A-Za-z0-9._-]/-}"
for stale in $(devices_named "$SIM_NAME"); do
    xcrun simctl delete "$stale" >/dev/null 2>&1 || true
done

SIM_ID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE" "$RUNTIME" 2>"$LOG_DIR/simctl.log")" \
    || fail "creazione del simulatore ($DEVICE_TYPE, $RUNTIME)" "$LOG_DIR/simctl.log"
print "Simulatore: $SIM_NAME (${RUNTIME##*.}, $SIM_ID)"

# --- xcodegen
print -n "xcodegen... "
(cd ios && xcodegen generate --quiet) >"$LOG_DIR/xcodegen.log" 2>&1 || fail "xcodegen" "$LOG_DIR/xcodegen.log"
print "ok"

XCB=(xcodebuild -project ios/ReadAlong.xcodeproj -scheme ReadAlong
     -destination "platform=iOS Simulator,id=$SIM_ID"
     -derivedDataPath ios/DerivedData)

# --- build
print -n "build... "
"${XCB[@]}" build >"$LOG_DIR/build.log" 2>&1 || fail "build" "$LOG_DIR/build.log"
# Nessun warning ammesso nel nostro codice (strict concurrency inclusa).
if grep -E "^/.*/ios/ReadAlong.*: warning:" "$LOG_DIR/build.log" | sort -u | head -20 | grep -q .; then
    grep -E "^/.*/ios/ReadAlong.*: warning:" "$LOG_DIR/build.log" | sort -u | head -20 >&2
    print -u2 "FALLITO: build con warning"
    exit 1
fi
print "ok"

# --- test
print -n "test... "
"${XCB[@]}" test >"$LOG_DIR/test.log" 2>&1 || fail "test" "$LOG_DIR/test.log"
print "ok ($(grep -Eo 'Test run with [0-9]+ tests?( in [0-9]+ suites?)? passed' "$LOG_DIR/test.log" | tail -1 || true))"

# --- makebook (solo se esiste)
if [[ -d tools/makebook ]]; then
    print -n "pytest makebook... "
    uv run --project tools/makebook pytest -q >"$LOG_DIR/pytest.log" 2>&1 || {
        print -u2 "FALLITO: pytest makebook"
        tail -30 "$LOG_DIR/pytest.log" >&2
        exit 1
    }
    print "ok ($(tail -1 "$LOG_DIR/pytest.log"))"
else
    print "pytest makebook: saltato (tools/makebook non esiste)"
fi

print "check.sh: VERDE"
