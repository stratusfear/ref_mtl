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
