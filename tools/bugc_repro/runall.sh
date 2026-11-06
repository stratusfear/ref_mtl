#!/bin/zsh
# X3: entry point for the Bug C sweep. Rebuild ./repro first (NOTES.md
# carries the clang line). Holds a display-sleep assertion for the whole
# sweep: a display sleep invalidates captures (NOTES.md, methodology guard).
DIR="$(cd "$(dirname "$0")" && pwd)"
caffeinate -i -w $$ &
CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT
"$DIR/sweep.sh" 6 default
"$DIR/sweep.sh" 6 wonly --worldonly
"$DIR/sweep.sh" 6 uionly --uionly
"$DIR/sweep.sh" 6 noattach --noattach
"$DIR/sweep.sh" 6 drawres --drawres
"$DIR/sweep.sh" 6 syncpresent --syncpresent
"$DIR/sweep.sh" 6 fullsync --fullsync
