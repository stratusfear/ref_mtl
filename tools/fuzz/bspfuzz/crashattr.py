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

"""AG4: attribute the died-signal rows of a batchhost run, one backtrace
per row (round-24).

AF4 called 23 SIGSEGV + 23 SIGBUS "game-side collision walks" on the
strength of ONE crash report.  This driver takes the died-signal rows of
a results.tsv and runs each map again under lldb, so every row gets its
own stop reason, its own frame #0 image and symbol, and its own list of
the images the crash touches.  macOS writes an .ips per crash only
until it decides to throttle repeats of the same binary (measured in the
round-24 release-host batch: 51 died-signal rows, ONE .ips in
~/Library/Logs/DiagnosticReports for the whole run), so the .ips is
harvested when it exists and the backtrace is the primary evidence.

The host is started exactly the way batchhost.py starts it (HOME = the
work dir, -cfgdir hgame, +map <name>), so the row is re-created, not
approximated.

usage:
  python3 crashattr.py --host <quake2> --datadir <data dir> \
      --maps <staged af*.bsp dir> --results <batchhost results.tsv> \
      --work <scratch dir> [--top 12] [--timeout 90] [--only <substr>]
output:
  <work>/attr.tsv   one row per died-signal map:
                    map signal frames images ips
  <work>/lldb/<map>.txt   the full lldb transcript
  <work>/reports/<map>.ips  the crash report, when one was written
  stdout: the per-row lines plus the tallies
"""
import argparse, collections, os, re, shutil, subprocess, sys, time

DIAG = os.path.expanduser("~/Library/Logs/DiagnosticReports")


def newest_ips(since):
    """The newest quake2 .ips modified after `since`, or None."""
    best, bt = None, since
    if not os.path.isdir(DIAG):
        return None
    for fn in os.listdir(DIAG):
        if not fn.startswith("quake2") or not fn.endswith(".ips"):
            continue
        p = os.path.join(DIAG, fn)
        m = os.path.getmtime(p)
        if m > bt:
            best, bt = fn, m
    return best


FRAME = re.compile(r"frame #\d+:\s+0x[0-9a-f]+\s+([^`\s]+)`([^\s+]+)")
STOP = re.compile(r"stop reason = ([^\n]+)")


def attribute(a, name):
    work = os.path.join(a.work, "cfg")
    os.makedirs(os.path.join(work, "hgame", "baseq2", "maps"), exist_ok=True)
    src = os.path.join(a.maps, name + ".bsp")
    dst = os.path.join(work, "hgame", "baseq2", "maps", name + ".bsp")
    if os.path.abspath(src) != os.path.abspath(dst):
        shutil.copyfile(src, dst)

    env = dict(os.environ, HOME=work)
    # AG4: this lldb (batch -b -o ...) does NOT run the queued -o commands
    # after `run` stops on a signal - the session simply ends at the stop
    # event (measured: a tiny SIGSEGV test program gets no backtrace at
    # all).  A -s command file does run them, so drive lldb that way.
    script = os.path.join(a.work, "lldb", "%s.cmds" % name)
    with open(script, "w") as f:
        f.write("run\nthread backtrace -c %d\nimage list\nquit\n" % a.top)
    cmd = [a.lldb, "-s", script,
           "--", a.host, "-datadir", a.datadir, "-cfgdir", "hgame",
           "+set", "game", "baseq2", "+set", "vid_renderer", "mtl",
           "+set", "vid_fullscreen", "0", "+set", "logfile", "2",
           "+map", name]
    t0 = time.time()
    try:
        # same cwd rule as batchhost.py / run_hostile.py: the host's own dir
        out = subprocess.run(cmd, cwd=os.path.dirname(a.host),
                             env=env, timeout=a.timeout,
                             capture_output=True, text=True)
        txt = out.stdout + "\n" + out.stderr
    except subprocess.TimeoutExpired as e:
        def _dec(x):
            if x is None:
                return ""
            return x.decode(errors="replace") if isinstance(x, bytes) else x
        txt = _dec(e.stdout) + _dec(e.stderr) + \
              "\n<hung: killed at %ds>" % a.timeout
    with open(os.path.join(a.work, "lldb", "%s.txt" % name), "w") as f:
        f.write(txt)

    stop = STOP.search(txt)
    frames = FRAME.findall(txt)
    images = []
    for img, sym in frames:
        images.append(img)
    top_img = frames[0][0] if frames else "?"
    top_sym = frames[0][1] if frames else "?"

    ips = None
    time.sleep(2)     # the crash report lands asynchronously after the stop
    new = newest_ips(t0)
    if new:
        ips = new
        shutil.copyfile(os.path.join(DIAG, new),
                        os.path.join(a.work, "reports", "%s.ips" % name))
    return (stop.group(1).strip() if stop else "?", top_img, top_sym,
            " ".join(dict.fromkeys(images)), ips)


def tally(a, rows, reparse, done):
    """attribute (or re-parse, from lldb/<map>.txt) each row and write
    attr.tsv + the tallies."""
    out = open(os.path.join(a.work, "attr.tsv"), "a" if done else "w")
    if not done:
        out.write("map\tsignal\tstop\ttop_image\ttop_symbol\timages\tips\n")
    byimg = collections.Counter()
    bysym = collections.Counter()
    nips = 0
    for name, sig in rows:
        if reparse:
            txt = open(os.path.join(a.work, "lldb", "%s.txt" % name),
                       errors="replace").read()
            stop = STOP.search(txt)
            frames = FRAME.findall(txt)
            img = frames[0][0] if frames else "?"
            sym = frames[0][1] if frames else "?"
            images = " ".join(dict.fromkeys(i for i, _ in frames))
            ips = "-"
            if not stop:
                stop = "HUNG(killed)" if "<hung" in txt else "?"
            else:
                stop = stop.group(1).strip()
        else:
            stop, img, sym, images, ips = attribute(a, name)
            if ips is None:
                ips = "-"
        byimg[img] += 1
        bysym[(img, sym)] += 1
        if ips != "-":
            nips += 1
        out.write("%s\t%s\t%s\t%s\t%s\t%s\t%s\n" %
                  (name, sig, stop, img, sym, images, ips))
        out.flush()
        print("%-8s sig %-3s %-28s %-14s %s" % (name, sig, stop[:28], img, sym),
              flush=True)
    out.close()

    print("\ntop frame, by image:")
    for img, n in byimg.most_common():
        print("  %-16s %d" % (img, n))
    print("top frame, by image+symbol:")
    for (img, sym), n in bysym.most_common():
        print("  %-16s %-40s %d" % (img, sym, n))
    print("crash reports harvested: %d of %d rows" % (nips, len(rows)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--datadir", required=True)
    ap.add_argument("--maps", required=True)
    ap.add_argument("--results", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--lldb", default="lldb")
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--only", default=None)
    ap.add_argument("--redo", action="store_true",
                    help="re-attribute maps already present in attr.tsv")
    ap.add_argument("--reparse", action="store_true",
                    help="do not run the host; re-tally from saved "
                         "lldb/<map>.txt transcripts")
    a = ap.parse_args()
    a.host = os.path.abspath(a.host)
    for sub in ("lldb", "reports"):
        os.makedirs(os.path.join(a.work, sub), exist_ok=True)

    rows = []
    done = set()
    prev = os.path.join(a.work, "attr.tsv")
    if os.path.exists(prev):		# resume support
        for ln in open(prev):
            p = ln.rstrip("\n").split("\t")
            if len(p) >= 7 and p[0] != "map":
                done.add(p[0])
    if a.reparse:
        done = set()		# re-parse every died row from its transcript
    with open(a.results) as f:
        head = f.readline()
        for ln in f:
            p = ln.rstrip("\n").split("\t")
            if len(p) < 4:
                continue
            if "died-signal" in p[3]:
                if a.only and a.only not in p[0]:
                    continue
                if p[0] in done and not a.redo:
                    continue
                rows.append((p[0], p[3].split("died-signal-")[1].split()[0]))
    print("died-signal rows to attribute: %d (%d already in attr.tsv)"
          % (len(rows), len(done)), flush=True)

    tally(a, rows, a.reparse, done)


main()
