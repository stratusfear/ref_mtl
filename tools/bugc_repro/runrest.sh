#!/bin/zsh
DIR="$(cd "$(dirname "$0")" && pwd)"
# hold a display-sleep assertion for the whole sweep
caffeinate -i -w $$ &
CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT
"$DIR/sweep.sh" 6 wonly --worldonly
"$DIR/sweep.sh" 6 uionly --uionly
"$DIR/sweep.sh" 6 noattach --noattach
"$DIR/sweep.sh" 6 drawres --drawres
"$DIR/sweep.sh" 6 syncpresent --syncpresent
"$DIR/sweep.sh" 6 fullsync --fullsync
