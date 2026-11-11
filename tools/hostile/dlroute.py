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

"""R27 AJ1.0 / AK2: the hostile-server download route, exercised.

Proves the download reach the premise cites (sv_user.c:437-451,
cl_download.c:212-222 skin names, cl_parse.c:1413-1417 stufftext)
end to end on the local machine.  Everything the drill needs is
built by --prepare; the rest of this docstring says what actually
selects what.

  server: q2ded from the gate build, HOME=--srchome, -cfgdir sgame,
    default game baseq2.  There is NO `-game evilmod`: the patched
    module is selected by landing at srchome/sgame/baseq2/game.dylib
    (the engine dlopens game.dylib from the gamedir).  The srchome
    game dir also holds models/evil/tris.md2 (v_blast with skin0
    renamed to a textures/*.tga path that exists nowhere else),
    that TGA, and maps b_dl1 (a byte-copy of base1 under a name the
    client lacks) + b_dl2 (base1 with the e1u1/metal2_1 texinfo
    renamed by mkbsp.py).
  client: the release host, HOME=--clihome, -cfgdir hgame,
    +connect localhost:<port>.  r_retexturing default 1, downloads
    land in hgame/baseq2 (= FS_Gamedir()).

Server-console control is raw stdin (--srv-cmd at t+5s, --srv-cmd2
at t+25s; this engine registers `map` but has NO `stuff` or
`changelevel` console command).  The svc_stufftext shape (a server
pushing console commands at one client - what the AJ1 lifecycle
drill needs) is produced by the PATCHED MODULE: ClientBegin
unicasts svc_stufftext ("set r_stb_budget 2048\nvid_restart") once
per game process when a client enters b_dl1.  The patch is
evilmod.patch (against yquake2 9dbf6992; applied to a COPY,
--yq2 never modified); --prepare copy-builds it with `make game`.

Note the exists-gate the drill demonstrates in reverse (round-28
AK1): CL_DownloadFilter skips names already on the client's search
path (yquake2 cl_download.c:600), so the hostile names must be
names the client LACKS - pre-stage them and the downloads stop.
`--dev` on the client shows loader Com_DPrintf lines, including
"LoadSTB() loaded:" for the network-supplied TGA.

usage (cold, from a clean checkout):
  python3 dlroute.py --prepare \
      [--yq2 PATH --datadir PATH] \
      --srchome DIR --clihome DIR [--port 28001] [--wait 60]
  # then, or in the same invocation (order above):
  python3 dlroute.py --srchome DIR --clihome DIR --srvmap base1 \
      --srv-cmd "map b_dl2" --dev

--prepare builds the module (a few tens of seconds).  It wipes
--srchome and --clihome first.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mkbsp  # noqa: E402  (pak_extract + the map mutators live there)

HOST = "/Volumes/Scratch/dev/quake2/yquake2/build-sdl3/release/quake2"
Q2DED = "/Volumes/Scratch/dev/quake2/yquake2/build-sdl3/release/q2ded"
DATADIR = "/Volumes/Scratch/dev/quake2/Quake 2.app/Contents/Resources"
YQ2 = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   os.pardir, os.pardir, os.pardir, "yquake2")


def sha1(p):
    return hashlib.sha1(open(p, "rb").read()).hexdigest()


EVIL_MODEL = "models/evil/tris.md2"
EVIL_SKIN = "textures/e1u1/r27evil_tex.tga"


def evil_md2(datadir):
    """v_blast's tris.md2 with the FIRST skin name rewritten to the
    TGA path (64-byte field at ofs_skins).  The MD2 header's
    ofs_skins/num_skins stay valid, so the client's precache walk
    reads the name straight out of the downloaded model header
    (cl_download.c:212-222) and asks the server for it."""
    buf = bytearray(mkbsp.pak_extract(datadir, "models/weapons/v_blast/tris.md2"))
    # header = 4-byte ident + 16 ints: version..num_frames then
    # ofs_skins, so ofs_skins is the 10th int after the ident
    # (offset 44); the 11th is ofs_st.
    ofs_skins = int.from_bytes(buf[4 + 4 * 10:4 + 4 * 11], "little")
    name = EVIL_SKIN.encode() + b"\0"
    buf[ofs_skins:ofs_skins + 64] = name.ljust(64, b"\0")
    # (byte-clear the whole 64-byte field: matches the round-27
    # artifact byte-for-byte, sha1 19c7af9d2d13cd31e41d0f6b4b1ee8db60a188aa)
    return bytes(buf)


def evil_tga():
    """24 bytes: an 18-byte TGA header claiming a 4096x4096 8-bit
    RLE image (stbi_info parses it; that is the 64 MB canvas claim
    the budget meters) followed by three 2-byte RLE packets - far
    short of the 16.7 M pixels.  Kept byte-for-byte identical to the
    round-27 artifact (sha1 81b14a60dbaee1aaca2d0867d3ba9782983630cb)
    so the report's quoted numbers stay checkable."""
    hdr = (b"\x00\x00\x0a" + b"\x00" * 9 +
           (4096).to_bytes(2, "little") + (4096).to_bytes(2, "little") +
           b"\x08\x00")
    return hdr + b"\xff\x42" * 3


def prepare(a):
    """Build the whole staging from a clean checkout: patched game
    module (copy-built), evil MD2, 24-byte TGA, b_dl1 + b_dl2."""
    for d in (a.srchome, a.clihome):
        shutil.rmtree(d, ignore_errors=True)
    gd = os.path.join(a.srchome, "sgame", "baseq2")
    for sub in ("maps", "models/evil", "textures/e1u1"):
        os.makedirs(os.path.join(gd, sub), exist_ok=True)
    os.makedirs(os.path.join(a.clihome, "hgame"), exist_ok=True)

    build = os.path.join(a.srchome, "evilmod-build")
    shutil.copytree(a.yq2, build,
                    ignore=shutil.ignore_patterns(".git", "build",
                                                  "debug", "release"))
    p = subprocess.run(["patch", "-p1", "-i",
                        os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     "evilmod.patch")],
                       cwd=build, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit("evilmod.patch did not apply (yquake2 source at %s "
                 "must sit at 9dbf6992; patch said:\n%s" % (a.yq2,
                                                            p.stderr))
    p = subprocess.run(["make", "game"], cwd=build,
                       capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit("make game failed in %s:\n%s" % (build, p.stdout[-2000:]))
    shutil.copy(os.path.join(build, "release", "baseq2", "game.dylib"),
                os.path.join(gd, "game.dylib"))

    open(os.path.join(gd, EVIL_MODEL), "wb").write(evil_md2(a.datadir))
    open(os.path.join(gd, EVIL_SKIN), "wb").write(evil_tga())
    # b_dl2 (renamed texinfo) out of the committed mkbsp.py mutators;
    # b_dl1 (for the module's stufftext leg) is a byte-copy of base1
    # under a name the client lacks, so the map download gates the walk.
    subprocess.run([sys.executable,
                    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "mkbsp.py"),
                    "--datadir", a.datadir, "--out",
                    os.path.join(a.srchome, "sgame")],
                   check=True, capture_output=True)
    open(os.path.join(gd, "maps", "b_dl1.bsp"), "wb").write(
        mkbsp.pak_extract(a.datadir, "maps/base1.bsp"))
    print("prepare: module, %s, %s, maps b_dl1+b_dl2 staged under %s"
          % (EVIL_MODEL, EVIL_SKIN, gd))
    print("prepare: evil md2 sha1=%s evil tga sha1=%s"
          % (sha1(os.path.join(gd, EVIL_MODEL)),
             sha1(os.path.join(gd, EVIL_SKIN))))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--srchome", required=True)
    ap.add_argument("--clihome", required=True)
    ap.add_argument("--prepare", action="store_true",
                    help="build all staging from this checkout first "
                         "(wipes --srchome/--clihome)")
    ap.add_argument("--yq2", default=os.path.abspath(YQ2),
                    help="yquake2 source tree (read-only; a copy is "
                         "built). default: ../../../yquake2")
    ap.add_argument("--datadir", default=DATADIR)
    ap.add_argument("--port", type=int, default=28001)
    ap.add_argument("--srvmap", default="base1",
                    help="server map; a map the client lacks makes the "
                         "map download gate the whole precache walk")
    ap.add_argument("--wait", type=int, default=45)
    ap.add_argument("--srv-cmd", action="append", default=[],
                    help="raw server-console command at t+5s "
                         "(e.g. 'map b_dl2')")
    ap.add_argument("--srv-cmd2", action="append", default=[],
                    help="raw server-console command at t+25s")
    ap.add_argument("--freshcli", action="store_true",
                    help="wipe the client HOME first")
    ap.add_argument("--dev", action="store_true",
                    help="developer 1 on the client: shows the loader's "
                         "Com_DPrintf lines (LoadSTB() loaded: ...)")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    if a.prepare:
        prepare(a)

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
            for c in a.srv_cmd:
                srv.stdin.write((c + "\n").encode())
            if a.srv_cmd:
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
