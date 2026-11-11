#!/bin/zsh
# Copyright (C) 2026 ref_mtl port
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or (at
# your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.

# fix_verify.sh — build + deploy + smoke-check ref_mtl in yquake2.
# Must be green before committing a ref_mtl work item.
#
# S1: the first version asserted almost nothing. The renderer was chosen only
# through the -cfgdir config (an archive-saved cvar, so a missing or stale
# config silently ran the smoke on gl3/soft - the host fallback does not
# match the error grep), a process that crashed at second 3 looked identical
# to one that ran the full 20 s (kill || true), and map-load failure only
# matched the generic "Can't find". It now requires the ref_mtl init banner
# and the map load line, checks the process is still alive before killing,
# and treats any wait status other than SIGTERM as a failure. DEBUG_LAYER=1
# runs the same smoke under MTL_DEBUG_LAYER=1 and includes the Metal
# diagnostic patterns (assert aborts etc.) that earlier rounds had to grep
# for by hand because this script's grep missed them.
#
# Round-19 (AB2) adds two content legs that close the gate's data gap: the
# smoke always ran baseq2 only, so the expansion-game path and the .cin
# decode/video-sampling path had never run under the gate on this machine
# (the round-7 L3/L4 and round-16 U1 "no cinematic content installed"
# caveats were exactly this gap: the installed bundle datadir does carry
# baseq2/video/*.cin and xatrix). Both legs derive the datadir from ROOT,
# run their own -cfgdir under a scratch dir, and auto-skip with a NOTICE
# when the data files are absent, so the gate
# stays runnable on machines without the full install:
#   expansion leg  +set game xatrix +map industry: asserts the expansion
#                  game code + assets render (Map: industry banner).
#   cinematic leg  +map idlog.cin with nextdemo "gamemap mintro" chaining:
#                  the chaining map's banner must land in the leg cfgdir's
#                  qconsole.log within CINWAIT (default 90 s), plus the
#                  usual liveness/exit-status/error-grep checks. AD1 (round
#                  21) observed this leg's exact command with temporary
#                  instrumentation in the engine's cinematic reader: the
#                  host opens video/idlog.cin, decodes all 82 frames of a
#                  well-formed classic .cin (20-byte header, 65536-byte
#                  Huffman counts table, then per-frame [cmd][palette?
#                  ][size][compressed][sound] records), stops on the
#                  cmd==2 EOF marker, and the nextdemo chain banner lands
#                  at ~7 s. So the leg does exercise the SCR_ReadNextFrame
#                  decode loop to clean EOF, not just open-and-chain. It
#                  still asserts NO frame/pixel/audio fidelity: the banner
#                  proves liveness, decode-to-EOF and chaining, not that
#                  the drawn frames are correct. The round-19 claim that
#                  these .cin files are broken "PACK"-container conversions
#                  decoding garbage until EOF is refuted; see the AD1 rows
#                  in REVIEW_EXTERNAL (round 21) for the measurement. The
#                  earlier claim that no valid .cin exists here was an
#                  artifact of a Python probe with the wrong record model
#                  (it skipped the counts table and the per-frame sound
#                  field). The gate does not vendor content either way.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "== embedded shaders fresh (make check-shaders) =="
( cd "$ROOT/ref_mtl" && make check-shaders )

echo "== build ref_mtl (WERR=1) =="
( cd "$ROOT/ref_mtl" && WERR=1 make )

echo "== deploy with fresh inode =="
cp "$ROOT/ref_mtl/release/ref_mtl.dylib" \
   "$ROOT/yquake2/build-sdl3/release/ref_mtl.dylib.tmp"
mv "$ROOT/yquake2/build-sdl3/release/ref_mtl.dylib.tmp" \
   "$ROOT/yquake2/build-sdl3/release/ref_mtl.dylib"

echo "== build yquake2 =="
# S1: a green host build used to hide behind >/dev/null; show the errors.
HOSTLOG=$(mktemp /tmp/fix_verify_host.XXXXXX)
if ! ( cd "$ROOT/yquake2" && make -C build-sdl3 >"$HOSTLOG" 2>&1 ); then
	echo "FAIL: yquake2 build failed:"
	tail -30 "$HOSTLOG"
	exit 1
fi
rm -f "$HOSTLOG"

# AL1.3 (round 29): fuzz-harness link leg.  The tools/fuzz harnesses
# link the loader TUs directly (stb.o and friends), so a ref_mtl
# change that adds a bridge symbol only the Metal TUs define breaks
# every fuzz target - which is exactly what AJ1 did at 8f7b206: the
# fuzzers did not link for four commits, invisible because no gate
# ever built them (the AJ1/AJ2/AK2/AK3 gate batteries all built the
# renderer + host + suite, not tools/fuzz).  This leg is build-only
# (measured: 7.6 s cold with the pinned toolchain, OBJDIR/BUILD into
# the run's scratch so nothing lands in the tree; the fuzzer
# sanitizers are compile-time, the link check needs no run).  A fuzz RUN needs the MacPorts
# toolchain the fuzz Makefile pins, and so does this LINK check
# (libFuzzer's main lives in the fuzzer runtime).
# leg cannot silently no-op on machines without clang-mp.  It must
# not no-op at all: silence here is how AJ1 survived.  (The link
# genuinely needs the fuzzer runtime for libFuzzer's main(): this
# host's plain cc has none - Xcode 21 dropped it - so the leg uses
# the Makefile's pinned toolchain, present here and verified by
# this leg itself; README.md documents the fallback recipe for
# other machines.  A FAIL on a machine that has no toolchain at
# all is the honest outcome, per the same reasoning.)
# SCRATCH (also used by the content legs below) holds the fuzz
# OBJDIR/BUILD; created here, removed by the trap.
SCRATCH=$(mktemp -d /tmp/fix_verify_legs.XXXXXX)
trap 'rm -rf "$SCRATCH"; echo "(game log: $LOG)"' EXIT
echo "== fuzz-harness link leg (tools/fuzz, build-only) =="
FUZZLOG=$(mktemp /tmp/fix_verify_fuzz.XXXXXX)
if ! ( cd "$ROOT/ref_mtl/tools/fuzz" \
	&& make BUILD="$SCRATCH/fuzz-build" \
		OBJDIR="$SCRATCH/fuzz-obj" fuzzers >"$FUZZLOG" 2>&1 ); then
	echo "FAIL: fuzz harnesses do not link:"
	tail -30 "$FUZZLOG"
	rm -f "$FUZZLOG"
	exit 1
fi
rm -f "$FUZZLOG"
echo "fuzz link leg OK (all six targets)"

LOG=$(mktemp /tmp/fix_verify_game_log.XXXXXX)
# Round-19: scratch for the content legs' cfgdirs/logs; removed on exit.
# (The SCRATCH dir + trap moved up to the fuzz link leg, round 29 AL1.3.)

# T3: FIX_VERIFY_GAME lets tools/fix_verify_selftest.sh point the smoke at a
# scripted stand-in that reproduces each failure mode the checks below are
# supposed to catch (fallback renderer, missing map banner, process died
# early, crash after our kill, injected Metal-diagnostic log lines). Unset,
# the smoke always runs the real host; nothing else reads this variable.
# Round-19: the stand-in also serves the content legs (it branches on the
# leg's argv) and reads FIX_VERIFY_FAULT/FIX_VERIFY_X_WAIT/FIX_VERIFY_CIN_*
# itself; fix_verify.sh passes no fault mode - a leg either runs for real
# or the stand-in script already decided what it will do.
GAME="${FIX_VERIFY_GAME:-$ROOT/yquake2/build-sdl3/release/quake2}"

# Content legs' data source: the installed bundle datadir, overridable so
# the selftest can prove the absent-data skip path.
# Default: the project-local bundle if present, else /Applications (where
# Quake 2.app lives on this machine now).
if [ -z "$FIX_VERIFY_DATADIR" ] && [ ! -d "$ROOT/Quake 2.app/Contents/Resources" ] \
	&& [ -d "/Applications/Quake 2.app/Contents/Resources" ]; then
	FIX_VERIFY_DATADIR="/Applications/Quake 2.app/Contents/Resources"
fi
DATADIR="${FIX_VERIFY_DATADIR:-$ROOT/Quake 2.app/Contents/Resources}"

# Error grep shared by all legs. Deliberately NOT matching the benign
# per-run noise the real host emits (OpenAL init failure, "Metal API
# Validation Enabled", GFXINFO, "No fixes found as ...", "couldn't exec
# yq2.cfg", OGG_PlayTrack) - verified against both content legs' logs.
ERRPAT='segmentation|signal [0-9]|ref_mtl:.*fail|failed to create|couldn'\''t load|Can'\''t find|assert|MTLDebug|leaked|EXC_|Fatal'

if [ -n "$DEBUG_LAYER" ]; then
	echo "== smoke run: 20s of jail1 under mtl_w0_test, vid_renderer mtl forced, Metal debug layer on =="
	export MTL_DEBUG_LAYER=1
else
	echo "== smoke run: 20s of jail1 under mtl_w0_test, vid_renderer mtl forced =="
fi
caffeinate -i -w $$ &
"$GAME" -cfgdir mtl_w0_test \
  +set vid_renderer mtl +map jail1 >"$LOG" 2>&1 &
GPID=$!
sleep 20
# S1: gone before our kill means the process died on its own - crash or
# early quit, both are smoke failures, not passes.
if ! kill -0 $GPID 2>/dev/null; then
	echo "FAIL: game process died within the smoke window; last log lines:"
	tail -20 "$LOG"
	exit 1
fi
kill $GPID 2>/dev/null || true
GRC=0
wait $GPID || GRC=$?
# S1: the only acceptable exits are SIGTERM (status 143) and yquake2's own
# clean-shutdown handler reacting to that SIGTERM (status 0); 139 (SEGV),
# 134 (abort) etc. mean the run crashed. A death BEFORE the kill is caught
# by the kill -0 check above, so "alive, then status 0" is the handler path.
if [ $GRC -ne 143 ] && [ $GRC -ne 0 ]; then
	echo "FAIL: game exited under its own power (status $GRC); last log lines:"
	tail -20 "$LOG"
	exit 1
fi
if [ ! -s $LOG ]; then
  echo "FAIL: game log is empty, game did not start"
  exit 1
fi
# S1: the smoke is only meaningful if ref_mtl itself came up and jail1
# actually loaded (the mtl_w0_test cfgdir no longer decides that alone).
if ! grep -q "Successfully initialized Metal 4 refresher!" $LOG; then
	echo "FAIL: ref_mtl never initialized (fallback renderer?); renderer-related log lines:"
	grep -iE "renderer|ref_|refresher" $LOG | tail -20
	exit 1
fi
# H3: the old dm1 was absent from the installed paks, so the map load
# silently fell back to the menu and the content part of the smoke was
# inert; map a real bundled map and fail on a missing map.
# S1: the map banner is now a positive requirement, not just the absence
# of "Can't find".
if ! grep -q "Map: jail1" $LOG; then
	echo "FAIL: jail1 never loaded (no map banner); last log lines:"
	tail -20 "$LOG"
	exit 1
fi
# S1: added the Metal diagnostic patterns the debug-layer run can emit -
# earlier rounds had to grep the log by hand because these were missing.
if grep -qiE "$ERRPAT" $LOG; then
  echo "FAIL: errors in game log:"; grep -inE "$ERRPAT" $LOG
  exit 1
fi
grep -E "ref_mtl" $LOG | tail -3
echo "main smoke leg OK"

# ---- expansion leg (round-19 AB2) ----------------------------------------
# Runs the xatrix game code over its own map: this is the only gate time
# any non-baseq2 game.dylib + asset tree ever rendered under the gate.
echo "== expansion leg: game xatrix, 5s of industry =="
if [ ! -e "$DATADIR/xatrix/game.dylib" ]; then
	echo "NOTICE: no expansion data at $DATADIR/xatrix - skipping expansion leg"
else
	XCFG="$SCRATCH/cfg-xatrix"
	mkdir -p "$XCFG/baseq2"
	# A real (writable) game dir, NOT a symlink into the datadir: with
	# game=xatrix the host writes config.cfg/qconsole.log through the
	# game dir, and a datadir symlink would drop those files inside the
	# installed bundle.  The xatrix pak0/game.dylib are found through
	# the -datadir search regardless.
	mkdir -p "$XCFG/xatrix"
	XLOG="$SCRATCH/xatrix.log"
	# stdout is block-buffered behind the redirect, so the map banner can
	# sit in the buffer for the whole window (verified on this host: it
	# only lands in the file at the shutdown flush). Read the banner from
	# the leg's own console log instead - +set logfile 2 flushes it per
	# console message, same trick as the cinematic leg.  The log lands
	# under the *current game dir*, so game=xatrix writes it to
	# cfg-xatrix/xatrix/, not cfg-xatrix/baseq2/.
	XCON="$XCFG/xatrix/qconsole.log"
	# The host joins HOME and the -cfgdir argument unconditionally (an
	# absolute -cfgdir lands under HOME, not where it looks), so the leg
	# points HOME at the scratch dir and passes a relative cfgdir.
	HOME="$SCRATCH" "$GAME" -datadir "$DATADIR" -cfgdir cfg-xatrix \
	  +set vid_renderer mtl +set vid_fullscreen 0 +set r_mode 4 \
	  +set logfile 2 +set game xatrix +map industry \
	  >"$XLOG" 2>&1 &
	XPID=$!
	XWAIT="${FIX_VERIFY_X_WAIT:-25}"
	xelapsed=0
	until grep -q "Map: industry" "$XCON" 2>/dev/null; do
		if ! kill -0 $XPID 2>/dev/null; then
			echo "FAIL: expansion leg process died before industry loaded; last log lines:"
			echo "--- qconsole.log tail:"; tail -20 "$XCON" 2>/dev/null
			echo "--- stdout tail:"; tail -20 "$XLOG"
			exit 1
		fi
		if [ $xelapsed -ge $XWAIT ]; then
			echo "FAIL: expansion leg never printed 'Map: industry' within ${XWAIT}s"
			echo "--- qconsole.log tail:"; tail -20 "$XCON" 2>/dev/null
			echo "--- stdout tail:"; tail -20 "$XLOG"
			kill -9 $XPID 2>/dev/null || true
			exit 1
		fi
		sleep 1
		xelapsed=$((xelapsed + 1))
	done
	sleep 5
	if ! kill -0 $XPID 2>/dev/null; then
		echo "FAIL: expansion leg died on its own after the map banner; last log lines:"
		tail -20 "$XLOG"
		exit 1
	fi
	kill $XPID 2>/dev/null || true
	XRC=0
	wait $XPID || XRC=$?
	if [ $XRC -ne 143 ] && [ $XRC -ne 0 ]; then
		echo "FAIL: expansion leg exited under its own power (status $XRC); last log lines:"
		tail -20 "$XLOG"
		exit 1
	fi
	if grep -qiE "$ERRPAT" "$XLOG" "$XCON"; then
		echo "FAIL: errors in expansion leg log:"; grep -inE "$ERRPAT" "$XLOG" "$XCON"
		exit 1
	fi
	echo "expansion leg OK (Map: industry at ${xelapsed}s, rc $XRC)"
fi

# ---- cinematic leg (round-19 AB2; AD1/AD2 round-21 correction) ------------
# Drives a shipped .cin through SCR_PlayCinematic, the SCR_ReadNextFrame
# decode loop and the RE_Cinematic x10/CinVideo raw-texture slot draw
# (round-7 L3/L4 area) live, then requires the nextdemo chain command to
# complete: the demo map's banner in the leg's own qconsole.log inside
# CINWAIT. AD1 (round 21) measured the leg's command with engine-side
# instrumentation: idlog.cin is a well-formed classic .cin, the host
# decodes all 82 frames to the cmd==2 EOF marker (~6 s), then chains.
# The leg therefore asserts open + full decode + chaining + liveness; it
# asserts no frame/pixel/audio fidelity. The round-19 note calling the
# shipped .cin content known-bad (PACK conversion, garbage decode) was
# wrong - see the AD1 rows in REVIEW_EXTERNAL.
echo "== cinematic leg: idlog.cin play-attempt + nextdemo gamemap chaining =="
if [ ! -f "$DATADIR/baseq2/video/idlog.cin" ]; then
	echo "NOTICE: no cinematic data at $DATADIR/baseq2/video - skipping cinematic leg"
else
	CCFG="$SCRATCH/cfg-cin"
	mkdir -p "$CCFG/baseq2"
	ln -s "$DATADIR/baseq2/video" "$CCFG/baseq2/video"
	echo 'set nextdemo "gamemap mintro"' > "$CCFG/baseq2/autoexec.cfg"
	CLOG="$CCFG/baseq2/qconsole.log"
	COUT="$SCRATCH/cin.stdout"
	CINWAIT="${FIX_VERIFY_CIN_WAIT:-90}"
	HOME="$SCRATCH" "$GAME" -datadir "$DATADIR" -cfgdir cfg-cin \
	  +set vid_renderer mtl +set vid_fullscreen 0 +set r_mode 4 \
	  +set logfile 2 +map idlog.cin \
	  >"$COUT" 2>&1 &
	CPID=$!
	celapsed=0
	cdone=0
	while [ $celapsed -lt $CINWAIT ]; do
		if [ -f "$CLOG" ] && grep -q "Map: mintro" "$CLOG"; then
			cdone=1
			break
		fi
		if ! kill -0 $CPID 2>/dev/null; then
			echo "FAIL: cinematic leg process died before the demo chain finished"
			echo "--- qconsole.log tail:"; tail -20 "$CLOG" 2>/dev/null
			echo "--- stdout tail:"; tail -20 "$COUT"
			exit 1
		fi
		sleep 1
		celapsed=$((celapsed + 1))
	done
	if [ $cdone -ne 1 ]; then
		echo "FAIL: cinematic leg: nextdemo chain never completed within ${CINWAIT}s"
		echo "--- qconsole.log tail:"; tail -20 "$CLOG" 2>/dev/null
		echo "--- stdout tail:"; tail -20 "$COUT"
		kill -9 $CPID 2>/dev/null || true
		exit 1
	fi
	kill $CPID 2>/dev/null || true
	CRC=0
	wait $CPID || CRC=$?
	if [ $CRC -ne 143 ] && [ $CRC -ne 0 ]; then
		echo "FAIL: cinematic leg exited under its own power (status $CRC); last log lines:"
		tail -20 "$COUT"
		exit 1
	fi
	if grep -qiE "$ERRPAT" "$CLOG" "$COUT"; then
		echo "FAIL: errors in cinematic leg logs:"; grep -inE "$ERRPAT" "$CLOG" "$COUT"
		exit 1
	fi
	echo "cinematic leg OK (engine path exercised, chain banner at ${celapsed}s, rc $CRC)"
fi

echo "fix_verify OK"
