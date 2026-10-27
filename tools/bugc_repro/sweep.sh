#!/bin/zsh
# sweep.sh N TAG [flags...] — run repro N times for 30s each, capture the
# repro window 3 times per run at its exact bounds, then analyze.
# Usage: ./sweep.sh 6 default --scan
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/bugc_runs
mkdir -p $OUT
N=$1; TAG=$2; shift 2
for i in $(seq 1 $N); do
  pkill -KILL -x "$DIR/repro" 2>/dev/null || true
  sleep 1
  D=$OUT/$TAG/$i
  mkdir -p $D
  "$DIR/repro" --secs 30 "$@" >$D/stdout.log 2>$D/stderr.log &
  PID=$!
  sleep 4
  # window bounds via System Events
  B=$(osascript <<EOF 2>/dev/null
tell application "System Events"
	tell (first process whose unix id is $PID)
		set p to position of window 1
		set s to size of window 1
		return (item 1 of p) & "," & (item 2 of p) & "," & (item 1 of s) & "," & (item 2 of s)
	end tell
end tell
EOF
)
  B=$(echo "$B" | sed 's/,,//g; s/ //g')
  if [ -z "$B" ]; then echo "no window for $TAG/$i"; kill $PID 2>/dev/null || true; continue; fi
  X=$(echo $B | cut -d, -f1); Y=$(echo $B | cut -d, -f2)
  W=$(echo $B | cut -d, -f3); H=$(echo $B | cut -d, -f4)
  for c in 1 2 3; do
    screencapture -x -R$X,$Y,$W,$H $D/cap$c.png || echo "capture failed $TAG/$i c$c"
    sleep 3
  done
  wait $PID 2>/dev/null || true
  echo "$TAG/$i captured at $X,$Y $W x $H"
done
python3 "$DIR/analyze.py" $OUT/$TAG
