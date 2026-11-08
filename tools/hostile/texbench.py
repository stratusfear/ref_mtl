#!/usr/bin/env python3
"""AI3 measurement (round 26): what within-cap canvas claims cost in
aggregate on the release host.

The AH1 cap bounds ONE texture; a hostile map names hundreds of
distinct texinfo textures, and each unique name pays separately.
This stages N crafted TGAs over N texture names a real map
references (loose textures/... in the -cfgdir game dir beats paks,
the AH1 route), then measures exactly the AH1 way: r_speeds 1,
0.5 s RSS samples, banner and first-frame timestamps off
qconsole.log.

kinds:
  t4096      4096x4096 8bpp RLE, truncated payload: within-cap
             claim decoding to a mostly-flat canvas (stb EOF-repeats)
  c1024x512  1024x512 8bpp RLE, COMPLETE payload: the shipped-set
             maximum (scan_img.py census: max side 1024, max
             524288 px) as the control

usage:
  python3 texbench.py --datadir <Resources dir> --map base1 \
      --kind t4096 --n 32 [--timeout 180] [--home DIR] [--names FILE]
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan_texinfo


def tga_rle(w, h, npx_runs=None, color=b"\x42"):
    """8bpp RLE TGA (type 10, the timeout-35106c89 shape); npx_runs
    None = complete solid payload, else only that many pixels of
    runs are written and the file ends (stb EOF-repeat fills the
    rest, so the canvas decodes mostly flat)."""
    hdr = struct.pack("<BBBHHBHHHHBB", 0, 0, 10, 0, 0, 0, 0, 0,
                      w, h, 8, 0)
    total = w * h if npx_runs is None else npx_runs
    out = bytearray(hdr)
    while total > 0:
        k = min(128, total)
        out += bytes([0x80 | (k - 1)]) + color
        total -= k
    return bytes(out)


KINDS = {
    "t4096": lambda: tga_rle(4096, 4096, npx_runs=384),
    "c1024x512": lambda: tga_rle(1024, 512),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--datadir", required=True)
    ap.add_argument("--map", required=True)
    ap.add_argument("--kind", required=True, choices=sorted(KINDS))
    ap.add_argument("--n", type=int, required=True)
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--home", default=None,
                    help="scratch HOME (default: <tmp>/ai3texbench)")
    ap.add_argument("--names", default=None,
                    help="read staged names from FILE instead of the BSP")
    a = ap.parse_args()

    if a.names:
        names = [l for l in open(a.names).read().split() if l]
    else:
        paks = [os.path.join(a.datadir, "baseq2", p)
                for p in sorted(os.listdir(os.path.join(a.datadir,
                                                        "baseq2")))
                if p.endswith(".pak")]
        mapsdir = os.path.join(a.datadir, "baseq2", "maps")
        seen = scan_texinfo.collect(paks +
                                    ([mapsdir] if os.path.isdir(mapsdir)
                                     else []))
        if a.map not in seen:
            raise SystemExit("map %s not found (have %d maps)"
                             % (a.map, len(seen)))
        names = seen[a.map]
    if a.n > len(names):
        raise SystemExit("map %s references only %d unique names"
                         % (a.map, len(names)))

    home = a.home or os.path.join(os.environ.get("TMPDIR", "/tmp"),
                                  "ai3texbench")
    shutil.rmtree(home, ignore_errors=True)
    gd = os.path.join(home, "hgame", "baseq2")
    os.makedirs(gd, exist_ok=True)
    blob = KINDS[a.kind]()
    for name in names[:a.n]:
        dst = os.path.join(gd, "textures", name + ".tga")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst, "wb").write(blob)
    qlog = os.path.join(gd, "qconsole.log")

    host = os.path.abspath(os.path.join(os.path.dirname(__file__), "..",
                                        "..", "..", "yquake2", "build-sdl3",
                                        "release", "quake2"))
    env = dict(os.environ, HOME=home)
    cmd = [host, "-datadir", a.datadir, "-cfgdir", "hgame",
           "+set", "game", "baseq2", "+set", "vid_renderer", "mtl",
           "+set", "vid_fullscreen", "0", "+set", "logfile", "2",
           "+set", "r_retexturing", "1", "+set", "r_speeds", "1",
           "+map", a.map]
    t0 = time.time()
    p = subprocess.Popen(cmd, cwd=os.path.dirname(host), env=env,
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    banner_t = first_t = None
    peak = 0
    samples = []
    while time.time() - t0 < a.timeout:
        if p.poll() is not None:
            break
        try:
            rss = int(subprocess.run(["ps", "-o", "rss=", "-p", str(p.pid)],
                                     capture_output=True,
                                     text=True).stdout.strip() or 0)
            peak = max(peak, rss)
            samples.append((time.time() - t0, rss // 1024))
        except Exception:
            pass
        if os.path.exists(qlog):
            txt = open(qlog, errors="replace").read()
            if banner_t is None and ("Map: %s" % a.map) in txt:
                banner_t = time.time() - t0
            if first_t is None and ("wpoly" in txt or "wpolys" in txt):
                first_t = time.time() - t0
        time.sleep(0.5)
    killed = p.poll() is None
    if killed:
        p.kill()
        p.wait()
    logs = open(qlog, errors="replace").read() if os.path.exists(qlog) \
        else ""
    refuse = sum(1 for ln in logs.splitlines() if "refusing to decode" in ln)
    oom = sum(1 for ln in logs.splitlines() if "outofmem" in ln.lower())
    print("%-10s n=%-4d banner=%s firstframe=%s peakRSS=%.0f MB "
          "refuse=%d oom=%d run=%.1fs killed=%s"
          % (a.kind, a.n,
             ("%.2f" % banner_t) if banner_t else "NONE",
             ("%.2f" % first_t) if first_t else "NONE",
             peak / 1024.0, refuse, oom, time.time() - t0, killed))
    traj = os.path.join(a.home or os.path.dirname(qlog),
                        "traj_%s_%d.txt" % (a.kind, a.n))
    with open(traj, "w") as o:
        for t, mb in samples:
            o.write("%.1f %d\n" % (t, mb))
    print("   traj -> %s" % traj)
    for ln in logs.splitlines():
        s = ln.strip()
        if ("ERROR:" in s and "OpenAL" not in s) or "refusing" in s or \
           "outofmem" in s.lower() or "couldn't load" in s:
            print("      | %s" % s[:130])


if __name__ == "__main__":
    main()
