#!/bin/zsh
DIR="$(cd "$(dirname "$0")" && pwd)"
caffeinate -i -w $$ &
CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT
"$DIR/sweep.sh" 6 direct --direct
"$DIR/sweep.sh" 6 clscene --clscene
"$DIR/sweep.sh" 6 maxdraw2 --maxdraw 2
