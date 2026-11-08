#!/usr/bin/env python3
"""AI3 helper: unique texture names per map (round 26).

A hostile map pays for one canvas per UNIQUE texinfo name, so the
cost benches (texbench.py) stage one crafted file per name the map
really references.  This lists those names: Q2 BSP v38, LUMP_TEXINFO
(5), texinfo_t 76 bytes with char texture[32] at offset 40; the BSP
directory entry at 8 + 8*lump is {fileofs, len}.  Paks are the
Yamagi "PACK" format (16-byte header, 64-byte dir records) as used
by every data dir this review gates against; loose maps are walked
recursively.

usage:
  python3 scan_texinfo.py <pak0.pak> [pak...] [dir ...] [--map NAME]
  without --map: per-map unique-name counts, sorted; with --map: the
  sorted name list for that map only.
"""
import os
import struct
import sys


def pak_files(path, suffix=".bsp"):
    with open(path, "rb") as f:
        tag, diroff, dirbytes, _ver = struct.unpack("<4s3i", f.read(16))
        if tag != b"PACK":
            return
        f.seek(diroff)
        for _ in range(dirbytes // 64):
            rec = f.read(64)
            if len(rec) < 64:
                return
            name = rec[:56].split(b"\0")[0].decode("ascii", "replace")
            ofs, size = struct.unpack_from("<ii", rec, 56)
            if name.lower().endswith(suffix) and 0 < size \
                    and 16 <= ofs and ofs + size <= diroff:
                here = f.tell()
                f.seek(ofs)
                yield name, f.read(size)
                f.seek(here)


def map_names(data):
    """Unique texinfo texture names, or None if not a v38 BSP."""
    if len(data) < 8 + 19 * 8 or data[:4] != b"IBSP" \
            or struct.unpack_from("<I", data, 4)[0] != 38:
        return None
    tofs = struct.unpack_from("<I", data, 8 + 5 * 8)[0]
    tlen = struct.unpack_from("<I", data, 8 + 5 * 8 + 4)[0]
    names = []
    for i in range(tlen // 76):
        rec = data[tofs + i * 76 + 40: tofs + i * 76 + 72]
        if len(rec) < 32:
            break
        names.append(rec.split(b"\0")[0].decode("ascii", "replace"))
    return names


def collect(args):
    """{(map basename without ext): [names]} over paks and dirs."""
    seen = {}
    for arg in args:
        if arg.lower().endswith(".pak"):
            for nm, data in pak_files(arg):
                ns = map_names(data)
                if ns:
                    seen[os.path.basename(nm)[:-4]] = sorted(set(ns))
        elif os.path.isdir(arg):
            for root, _, fs in os.walk(arg):
                for fn in fs:
                    if not fn.endswith(".bsp"):
                        continue
                    data = open(os.path.join(root, fn), "rb").read()
                    ns = map_names(data)
                    if ns:
                        seen[fn[:-4]] = sorted(set(ns))
    return seen


def main():
    args = sys.argv[1:]
    want = None
    if "--map" in args:
        k = args.index("--map")
        want = args[k + 1]
        del args[k:k + 2]
    seen = collect(args)
    if want:
        for n in seen.get(want, []):
            print(n)
        return
    for m, ns in sorted(seen.items(), key=lambda kv: -len(kv[1])):
        print("%8d  %s" % (len(ns), m))


if __name__ == "__main__":
    main()
