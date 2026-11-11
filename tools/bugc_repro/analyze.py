#!/usr/bin/env python3
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

# analyze.py DIR — for each run subdir, count strict-mask poison pixels and
# animated_diff (whether the display is actually animating) in each capture.
import sys, os, glob, subprocess, tempfile
try:
    from PIL import Image
except ImportError:
    Image = None

def load_png(path):
    if Image:
        im = Image.open(path).convert('RGB')
        return im.load(), im.size
    # fallback: dump to raw via sips
    return None, None

def main():
    root = sys.argv[1]
    total_poisoned = total_captures = 0
    for run in sorted(glob.glob(os.path.join(root, '*'))):
        caps = sorted(glob.glob(os.path.join(run, 'cap*.png')))
        if not caps:
            continue
        imgs, sizes = [], []
        for c in caps:
            px, sz = load_png(c)
            imgs.append(px); sizes.append(sz)
        counts = []
        diffs = []
        for i, px in enumerate(imgs):
            if px is None:
                continue
            w, h = sizes[i]
            cnt = 0
            for y in range(64, h):      # skip titlebar
                for x in range(w):
                    r, g, b = px[x, y]
                    if abs(r-234) <= 12 and abs(g-51) <= 12 and abs(b-247) <= 12:
                        cnt += 1
            counts.append(cnt)
        # animated diff between consecutive captures
        for i in range(len(imgs)-1):
            if imgs[i] is None or imgs[i+1] is None:
                continue
            w, h = sizes[i]
            d = 0
            step = 4
            for y in range(64, h, step):
                for x in range(0, w, step):
                    a = imgs[i][x, y]; b = imgs[i+1][x, y]
                    if abs(a[0]-b[0]) + abs(a[1]-b[1]) + abs(a[2]-b[2]) > 24:
                        d += 1
            diffs.append(d)
        poisoned = sum(1 for c in counts if c > 0)
        total_poisoned += poisoned
        total_captures += len(counts)
        print(f"{os.path.basename(run)}: poison={counts} animated_diff={diffs}")
    print(f"== {os.path.basename(root)}: {total_poisoned}/{total_captures} captures poisoned ==")

if __name__ == '__main__':
    main()
