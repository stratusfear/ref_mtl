#!/bin/zsh
DIR="$(cd "$(dirname "$0")" && pwd)"
caffeinate -i -w $$ &
CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT
"$DIR/sweep.sh" 6 privscene --privscene
"$DIR/sweep.sh" 6 newcb --newcb
"$DIR/sweep.sh" 6 maxdraw1 --maxdraw 1
