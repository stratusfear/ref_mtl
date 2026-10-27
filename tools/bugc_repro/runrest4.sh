#!/bin/zsh
DIR="$(cd "$(dirname "$0")" && pwd)"
caffeinate -i -w $$ &
CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT
"$DIR/sweep.sh" 6 hyb_yes --hybrid --yes
"$DIR/sweep.sh" 6 direct_yes --direct --yes
