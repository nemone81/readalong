#!/bin/zsh
# Verifica completa del repo: xcodegen + build + test iOS, poi pytest di
# makebook se presente. Da lanciare dalla root del repo (o da dove si vuole:
# lo script si sposta da solo). Output filtrato: esito e, se fallisce, le
# righe `error:`.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

LOG_DIR="$(mktemp -d -t readalong-check)"
trap 'rm -rf "$LOG_DIR"' EXIT

fail() {
    local step="$1" log="$2"
    print -u2 "FALLITO: $step"
    # Prima le righe di errore del compilatore/test; se non ce ne sono, la coda del log.
    if ! grep -E "error:|\*\* (BUILD|TEST) FAILED|✘|Test .* failed" "$log" | sort -u | head -40 >&2; then
        tail -20 "$log" >&2
    fi
    exit 1
}

# --- Simulatore: "iPhone 17" se c'e', altrimenti il primo iPhone disponibile,
# sempre con runtime iOS >= 26 (il deployment target). A parita' di nome vince
# il runtime piu' recente.
pick_simulator() {
    xcrun simctl list devices available | awk '
        /^-- iOS / { split($3, v, "."); ok = (v[1] + 0 >= 26); next }
        /^-- /     { ok = 0; next }
        ok && /^ +iPhone / {
            line = $0
            sub(/^ +/, "", line)
            name = line; sub(/ \([0-9A-F-]+\).*$/, "", name)
            match(line, /\([0-9A-F-]{36}\)/)
            udid = substr(line, RSTART + 1, RLENGTH - 2)
            if (name == "iPhone 17") preferred = udid "\t" name
            if (first == "") first = udid "\t" name
        }
        END {
            if (preferred != "") print preferred
            else if (first != "") print first
        }'
}

SIM="$(pick_simulator)"
if [[ -z "$SIM" ]]; then
    print -u2 "FALLITO: nessun simulatore iPhone con iOS >= 26 disponibile"
    exit 1
fi
SIM_ID="${SIM%%$'\t'*}"
SIM_NAME="${SIM#*$'\t'}"
print "Simulatore: $SIM_NAME ($SIM_ID)"

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
