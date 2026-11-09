#!/usr/bin/env python3
"""R27 AJ1.0 / AJ1.4: the hostile-server download route, exercised.

Proves the download reach the premise cites (sv_user.c:437-451,
cl_download.c:212-222 skin names, cl_parse.c:1413-1417 stufftext)
end to end on the local machine:

  server: q2ded from the gate build, HOME=--srchome, -game evilmod
    (a scratch copy-built game module that precaches one extra
    model), game dir holds models/evil/tris.md2 (v_blast with one
    skin name rewritten to a textures/*.tga path) and a tiny TGA
    under that name.
  client: the release host, HOME=--clihome (fresh), same -game,
    +connect localhost:<port>.  r_retexturing default 1.

The server's stdin is a pipe: --stuff lines run as `stuff <id> <cmd>`
server-console commands - the svc_stufftext shape (a server sending
`set <cvar> <v>` to the client).  Samples client RSS at 0.5 s,
timestamps banner/first-r_speeds-frame off the client qconsole.log.

usage:
  python3 dlroute.py --srchome DIR --clihome DIR [--port 28001]
      [--wait 45] [--stuff "set r_stb_budget 0"]... [--keep]
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import time

HOST = "/Volumes/Scratch/dev/quake2/yquake2/build-sdl3/release/quake2"
Q2DED = "/Volumes/Scratch/dev/quake2/yquake2/build-sdl3/release/q2ded"
DATADIR = "/Volumes/Scratch/dev/quake2/Quake 2.app/Contents/Resources"


def sha1(p):
    return hashlib.sha1(open(p, "rb").read()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--srchome", required=True)
    ap.add_argument("--clihome", required=True)
    ap.add_argument("--port", type=int, default=28001)
    ap.add_argument("--srvmap", default="base1",
                    help="server map; a map the client lacks makes the "
                         "map download gate the whole precache walk")
    ap.add_argument("--wait", type=int, default=45)
    ap.add_argument("--stuff", action="append", default=[],
                    help="server-console 'stuff 0 <cmd>' at t+5s")
    ap.add_argument("--srv-cmd", action="append", default=[],
                    help="raw server-console command at t+5s "
                         "(e.g. 'changelevel base1')")
    ap.add_argument("--srv-cmd2", action="append", default=[],
                    help="raw server-console command at t+25s")
    ap.add_argument("--stuff2", action="append", default=[],
                    help="server-console 'stuff 0 <cmd>' at t+40s")
    ap.add_argument("--freshcli", action="store_true",
                    help="wipe the client HOME first")
    ap.add_argument("--dev", action="store_true",
                    help="developer 1 on the client: shows the loader's "
                         "Com_DPrintf lines (LoadSTB() loaded: ...)")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    if a.freshcli:
        shutil.rmtree(a.clihome, ignore_errors=True)
        os.makedirs(os.path.join(a.clihome, "hgame"), exist_ok=True)

    env_s = dict(os.environ, HOME=a.srchome)
    env_c = dict(os.environ, HOME=a.clihome)
    slog = os.path.join(a.srchome, "sgame", "baseq2", "qconsole.log")

    srv = subprocess.Popen(
        [Q2DED, "-datadir", DATADIR, "-cfgdir", "sgame",
         "+set", "port", str(a.port),
         "+set", "allow_download", "1", "+set", "deathmatch", "0",
         "+set", "logfile", "2", "+map", a.srvmap],
        cwd=os.path.dirname(Q2DED), env=env_s, stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    clog = os.path.join(a.clihome, "hgame", "baseq2", "qconsole.log")
    cli = subprocess.Popen(
        [HOST, "-datadir", DATADIR, "-cfgdir", "hgame",
         "+set", "vid_renderer", "mtl", "+set", "vid_fullscreen", "0",
         "+set", "logfile", "2", "+set", "r_speeds", "1",
         "+set", "developer", "1" if a.dev else "0",
         "+connect", "localhost:%d" % a.port],
        cwd=os.path.dirname(HOST), env=env_c,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    t0 = time.time()
    peak = 0
    banner_t = first_t = None
    stuffed = False
    stuffed2 = False
    ncmd = 0
    traj = []
    while time.time() - t0 < a.wait:
        if cli.poll() is not None or srv.poll() is not None:
            break
        try:
            rss = int(subprocess.run(["ps", "-o", "rss=", "-p", str(cli.pid)],
                                     capture_output=True,
                                     text=True).stdout.strip() or 0)
            peak = max(peak, rss)
            traj.append((time.time() - t0, rss // 1024))
        except Exception:
            pass
        if not stuffed and time.time() - t0 > 5:
            for s in a.stuff:
                srv.stdin.write(("stuff 0 %s\n" % s).encode())
            for c in a.srv_cmd:
                srv.stdin.write((c + "\n").encode())
            if a.stuff or a.srv_cmd:
                srv.stdin.flush()
            stuffed = True
        if not stuffed2 and a.srv_cmd2 and time.time() - t0 > 25:
            for c in a.srv_cmd2:
                srv.stdin.write((c + "\n").encode())
            srv.stdin.flush()
            stuffed2 = True
        if os.path.exists(clog):
            txt = open(clog, errors="replace").read()
            if banner_t is None and ("Map: %s" % a.srvmap) in txt:
                banner_t = time.time() - t0
            if first_t is None and ("wpoly" in txt or "wpolys" in txt):
                first_t = time.time() - t0
        time.sleep(0.5)
    for p in (cli, srv):
        if p.poll() is None:
            p.kill()
            p.wait()
    try:
        srv.stdin.close()
    except Exception:
        pass

    ctxt = open(clog, errors="replace").read() if os.path.exists(clog) else ""
    print("client rc=%s srv rc=%s run=%.1fs banner=%s firstframe=%s "
          "peakRSS=%.0f MB" % (cli.poll(), srv.poll(), time.time() - t0,
                               ("%.2f" % banner_t) if banner_t else "NONE",
                               ("%.2f" % first_t) if first_t else "NONE",
                               peak / 1024.0))
    trajp = os.path.join(a.clihome, "traj_dl.txt")
    with open(trajp, "w") as o:
        for t, mb in traj:
            o.write("%.1f %d\n" % (t, mb))
    print("client RSS traj -> %s" % trajp)

    # what landed in the client's game dir
    gd = os.path.join(a.clihome, "hgame", "baseq2")
    landed = []
    for root, _, fs in os.walk(gd):
        for fn in fs:
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, gd)
            if rel in ("qconsole.log", "config.cfg", "autoexec.cfg") or \
                    rel.endswith(".txt"):
                continue
            landed.append((rel, os.path.getsize(p), sha1(p)))
    print("client game dir (%s):" % gd)
    for rel, sz, sh in sorted(landed):
        print("   %-46s %8d B sha1=%s" % (rel, sz, sh))

    print("client console (interesting lines):")
    for ln in ctxt.splitlines():
        s = ln.strip()
        if not s:
            continue
        low = s.lower()
        if ("download" in low or "refusing" in low or "couldn't load" in low
                or "outofmem" in low or "budget" in low
                or ("error" in low and "openal" not in low)
                or "stb" in low or "metal2_1" in low
                or "bad image" in low):
            print("   | %s" % s[:170])
    stxt = open(slog, errors="replace").read() if os.path.exists(slog) else ""
    print("server console (download lines):")
    for ln in stxt.splitlines():
        if "download" in ln.lower():
            print("   | %s" % ln.strip()[:170])


if __name__ == "__main__":
    main()
