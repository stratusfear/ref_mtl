#!/bin/zsh
# fix_verify_selftest.sh - T3: prove the S1 detection logic in
# fix_verify.sh actually fires.
#
# S1 rewrote fix_verify.sh to catch five failure modes that the old
# version passed silently: a fallback renderer standing in for
# ref_mtl, a map that never loads, a game process that died on its own
# before our kill, a crash between our kill and wait, and Metal
# diagnostic output (asserts, leaks, EXC_) in the log. None of that
# detection had a test: the only evidence S1 shipped was one green
# pass, which cannot distinguish "check present" from "check armed".
#
# This script injects each failure mode through the FIX_VERIFY_GAME
# hook in fix_verify.sh - a scripted stand-in for the game binary that
# reproduces the exact log/exit behaviour of the real fault - and
# requires fix_verify.sh to exit nonzero *and* print the matching
# FAIL line for each. It closes with a positive control: the unpatched
# smoke on the real host must still print fix_verify OK, so the
# negative runs cannot be passing on a broken script.
#
# Cost: five injected runs at the smoke window length plus one real
# run, ~3 min total including the incremental rebuilds fix_verify.sh
# does per run. Not part of the per-finding gate; run it when
# fix_verify.sh itself changes.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$ROOT/ref_mtl/tools/fix_verify.sh"

SELF=$(mktemp -d /tmp/fix_verify_selftest.XXXXXX)
trap 'rm -rf "$SELF"' EXIT

# The stand-ins mimic what the real game does over the 20 s smoke
# window. The banner and map strings are byte-identical to what
# ref_mtl and the host print, so the checks see genuine passes for
# everything except the injected fault.
BANNER="Successfully initialized Metal 4 refresher!"

# fallback renderer: loads fine, runs the full window, but was not
# ref_mtl - the old script saw a clean 20 s and an innocent log.
cat > "$SELF/fallback.sh" <<EOF
echo "Console: refresher: gl3"
echo "$BANNER but not" | sed 's/ Metal 4 / OpenGL /'
sleep 25
EOF

# map never loaded: ref_mtl came up, but the +map target is missing
# and the game sits at the menu (the H3 dm1 case).
cat > "$SELF/nomap.sh" <<EOF
echo "$BANNER"
echo "Can't find maps/bogus.bsp"
sleep 25
EOF

# died early: clean exit at second 5, well before the smoke kill -
# the old "kill || true" made this look like a full run.
cat > "$SELF/died.sh" <<EOF
echo "$BANNER"
echo "Map: jail1"
sleep 5
EOF

# crashed after our kill: survives the liveness check, ignores the
# SIGTERM, then takes SIGSEGV, so wait reports 139.
cat > "$SELF/crash.sh" <<EOF
echo "$BANNER"
echo "Map: jail1"
trap '' TERM
sleep 22
kill -SEGV \$\$
EOF

# Metal diagnostics in the log: a run that is clean by every other
# check (banner, map, survived to the kill, SIGTERM exit) but whose
# log carries the debug-layer leak/assert output earlier rounds had
# to grep for by hand.
cat > "$SELF/diag.sh" <<EOF
echo "$BANNER"
echo "Map: jail1"
echo "MTLDebugLeakedBuffer: leaked object of type 'Buffer'"
echo "Assertion failure in R_ResolveLights"
sleep 25
EOF

chmod +x "$SELF"/*.sh

fails=0
expect_fail() {
	local name="$1" game="$2" want="$3" debug="$4"
	local out rc
	rc=0
	if [ "$debug" = y ]; then
		out=$(DEBUG_LAYER=1 FIX_VERIFY_GAME="$game" sh "$VERIFY" 2>&1) || rc=$?
	else
		out=$(FIX_VERIFY_GAME="$game" sh "$VERIFY" 2>&1) || rc=$?
	fi
	if [ $rc -eq 0 ]; then
		echo "SELFTEST FAIL[$name]: fix_verify.sh passed a run with the fault injected"
		fails=$((fails + 1))
		return
	fi
	if ! echo "$out" | grep -qF "$want"; then
		echo "SELFTEST FAIL[$name]: exited $rc but not with '$want':"
		echo "$out" | grep -F FAIL | head -3
		fails=$((fails + 1))
		return
	fi
	echo "SELFTEST ok[$name]: caught by \"$want\""
}

expect_fail fallback  "$SELF/fallback.sh" "FAIL: ref_mtl never initialized (fallback renderer?)" n
expect_fail nomap     "$SELF/nomap.sh"    "FAIL: jail1 never loaded (no map banner)"              n
expect_fail died      "$SELF/died.sh"     "FAIL: game process died within the smoke window"       n
expect_fail crash     "$SELF/crash.sh"    "FAIL: game exited under its own power (status 139)"    n
expect_fail diag      "$SELF/diag.sh"     "FAIL: errors in game log"                              y

# Positive control: with no injection the same script must still go
# green, otherwise the five passes above prove nothing.
if sh "$VERIFY" >"$SELF/positive.log" 2>&1; then
	echo "SELFTEST ok[control]: real smoke still prints \"$(grep 'fix_verify OK' "$SELF/positive.log")\""
else
	echo "SELFTEST FAIL[control]: real smoke failed with the selftest harness present"
	tail -15 "$SELF/positive.log"
	fails=$((fails + 1))
fi

if [ $fails -ne 0 ]; then
	echo "fix_verify_selftest: $fails case(s) failed"
	exit 1
fi
echo "fix_verify_selftest OK"
