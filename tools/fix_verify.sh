#!/bin/zsh
# fix_verify.sh — build + deploy + smoke-check ref_mtl in yquake2.
# Must be green before committing a ref_mtl work item.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "== build ref_mtl (WERR=1) =="
( cd "$ROOT/ref_mtl" && WERR=1 make )

echo "== deploy with fresh inode =="
cp "$ROOT/ref_mtl/release/ref_mtl.dylib" \
   "$ROOT/yquake2/build-sdl3/release/ref_mtl.dylib.tmp"
mv "$ROOT/yquake2/build-sdl3/release/ref_mtl.dylib.tmp" \
   "$ROOT/yquake2/build-sdl3/release/ref_mtl.dylib"

echo "== build yquake2 =="
( cd "$ROOT/yquake2" && make -C build-sdl3 >/dev/null )

echo "== smoke run: 20s of dm1 under mtl_w0_test =="
LOG=/tmp/fix_verify_game.log
"$ROOT/yquake2/build-sdl3/release/yquake2" -cfgdir mtl_w0_test \
  +map dm1 +timedemo demo1 >$LOG 2>&1 &
GPID=$!
sleep 20
kill $GPID 2>/dev/null || true
if grep -qiE "segmentation|signal|error|failed to" $LOG; then
  echo "FAIL: errors in game log:"; grep -iE "segmentation|signal|error|failed to" $LOG
  exit 1
fi
grep -E "cl_frame|ref_mtl" $LOG | tail -3
echo "fix_verify OK"
