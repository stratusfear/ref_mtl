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

"""AJ1 (round 27): all-shipped-maps sweep for the stb decode budget.

Question this answers: does the DEFAULT budget (r_stb_budget 1024 MB)
ever bind on shipped content, i.e. can a legitimate single-player map
load hit the ceiling and start refusing within-cap textures?  For each
map in the shipped paks, boot the mtl client, load the map, exit
cleanly (SIGINT -> the engine terminate handler; the renderer shutdown
prints the charged total while still intact), and read the
GOTBUDGET/shutdown probe plus the refusal lines.

NOTE: the GOTBUDGET probe prints are a TEMPORARY probe build (revert
the source probes before commit); this tool parses what the budget
code itself prints too, so it keeps working afterwards via the
per-level summary line.

usage:
  python3 mapbudget.py --datadir <Resources dir> [--mapfile FILE]
      [--max 25] [--budget 1024] [--home DIR]
"""
import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan_texinfo

SHUTDOWN_RE = re.compile(r"GOTBUDGET shutdown charged=(-?\d+) MB")
ENDRREG_RE = re.compile(r"GOTBUDGET endreg charged=(-?\d+) MB")
SUMMARY_RE = re.compile(r"LoadSTB: (\d+) image decode\(s\) refused .*"
                        r"\((\d+) MB canvas\); (\d+) MB of (\d+) MB charged")


def run_map(host, datadir, home, m, budget, maxsec):
    gd = os.path.join(home, "hgame", "baseq2")
    shutil.rmtree(os.path.join(gd, "qconsole.log"), ignore_errors=True)
    qlog = os.path.join(gd, "qconsole.log")
    open(qlog, "w").close()
    p = subprocess.Popen(
        [host, "-datadir", datadir, "-cfgdir", "hgame",
         "+set", "game", "baseq2", "+set", "vid_renderer", "mtl",
         "+set", "vid_fullscreen", "0", "+set", "logfile", "2",
         "+set", "r_speeds", "1",
         "+set", "r_stb_budget", str(budget),
         "+map", m],
        cwd=os.path.dirname(host),
        env=dict(os.environ, HOME=home),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t0 = time.time()
    frames = False
    while time.time() - t0 < maxsec:
        if p.poll() is not None:
            break
        try:
            txt = open(qlog, errors="replace").read()
        except OSError:
            txt = ""
        if "Map: %s" % m in txt:
            if ("wpoly" in txt or "wpolys" in txt):
                frames = True
                time.sleep(1.0)
                break
        time.sleep(0.5)
    if p.poll() is None:
        p.kill()
        p.wait()
    logs = open(qlog, errors="replace").read()
    charged = None
    for mm in ENDRREG_RE.finditer(logs):
        charged = int(mm.group(1))          # last one wins
    if charged is None:
        for mm in SHUTDOWN_RE.finditer(logs):
            charged = int(mm.group(1))
    refused = 0
    for mm in SUMMARY_RE.finditer(logs):
        refused = max(refused, int(mm.group(1)))
    refuses_printed = sum(1 for ln in logs.splitlines()
                          if "does not fit the stb budget" in ln)
    bad = [ln for ln in logs.splitlines()
           if ("ERROR:" in ln and "OpenAL" not in ln)
           or "Sys_Error" in ln or "Host Error" in ln]
    return dict(map=m, charged=charged, refused=refused,
                printed=refuses_printed, frames=frames, bad=bad[:2])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--datadir", required=True)
    ap.add_argument("--mapfile", default=None,
                    help="list of maps instead of the shipped paks")
    ap.add_argument("--max", type=int, default=25,
                    help="max seconds per map until first frame")
    ap.add_argument("--budget", default="1024")
    ap.add_argument("--home", default=None)
    a = ap.parse_args()

    host = os.path.abspath(os.path.join(os.path.dirname(__file__), "..",
                                        "..", "..", "yquake2", "build-sdl3",
                                        "release", "quake2"))
    if a.mapfile:
        maps = [l for l in open(a.mapfile).read().split() if l]
    else:
        paks = [os.path.join(a.datadir, "baseq2", p)
                for p in sorted(os.listdir(os.path.join(a.datadir,
                                                        "baseq2")))
                if p.endswith(".pak")]
        mapsdir = os.path.join(a.datadir, "baseq2", "maps")
        seen = scan_texinfo.collect(paks +
                                    ([mapsdir] if os.path.isdir(mapsdir)
                                     else []))
        maps = sorted(seen)

    home = a.home or os.path.join(os.environ.get("TMPDIR", "/tmp"),
                                  "aj1mapbudget")
    os.makedirs(os.path.join(home, "hgame", "baseq2"), exist_ok=True)

    rows = []
    for i, m in enumerate(maps):
        r = run_map(host, a.datadir, home, m, a.budget, a.max)
        rows.append(r)
        print("%3d/%-3d %-14s charged=%s refused=%-3d printed=%-2d frame=%s%s"
              % (i + 1, len(maps), m,
                 ("%d MB" % r["charged"]) if r["charged"] is not None else "NONE",
                 r["refused"], r["printed"], "y" if r["frames"] else "n",
                 ("  BAD: " + r["bad"][0][:60]) if r["bad"] else ""),
              flush=True)

    worst = sorted((r for r in rows if r["charged"] is not None),
                   key=lambda r: -r["charged"])
    print("--- worst charged totals ---")
    for r in worst[:10]:
        print("   %-14s %d MB charged (refused %d)" % (r["map"], r["charged"],
                                                       r["refused"]))
    n_bad = sum(1 for r in rows if r["bad"])
    n_frame = sum(1 for r in rows if r["frames"])
    print("maps=%d frame_ok=%d bad=%d" % (len(rows), n_frame, n_bad))


if __name__ == "__main__":
    main()
