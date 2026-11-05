#!/bin/zsh
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

LOG=$(mktemp /tmp/fix_verify_game_log.XXXXXX)
trap 'echo "(game log: $LOG)"' EXIT

if [ -n "$DEBUG_LAYER" ]; then
	echo "== smoke run: 20s of jail1 under mtl_w0_test, vid_renderer mtl forced, Metal debug layer on =="
	export MTL_DEBUG_LAYER=1
else
	echo "== smoke run: 20s of jail1 under mtl_w0_test, vid_renderer mtl forced =="
fi
caffeinate -i -w $$ &
"$ROOT/yquake2/build-sdl3/release/quake2" -cfgdir mtl_w0_test \
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
if grep -qiE "segmentation|signal [0-9]|ref_mtl:.*fail|failed to create|couldn't load|Can't find|assert|MTLDebug|leaked|EXC_|Fatal" $LOG; then
  echo "FAIL: errors in game log:"; grep -inE "segmentation|signal [0-9]|ref_mtl:.*fail|failed to create|couldn't load|Can't find|assert|MTLDebug|leaked|EXC_|Fatal" $LOG
  exit 1
fi
grep -E "ref_mtl" $LOG | tail -3
echo "fix_verify OK"
