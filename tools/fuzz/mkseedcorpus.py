#!/usr/bin/env python3
"""
AE1: build the libFuzzer seed corpora from the shipped game data.

Reads every pak*.pak plus the loose image/model files under the
given game directories (default: the yquake2 build tree) and drops
each real loader input, byte for byte, into corpus/<target>/. The
corpora are NOT committed; they are generated on the fuzzing machine
(see README.md).

No prefixes or wrappers: a corpus file IS the byte stream a loader
would see from FS_LoadFile(), so the format magic survives intact.

Usage: python3 mkseedcorpus.py [--src DIR ...] [--out DIR]
"""

import argparse
import os
import struct
import sys

# Extension sets per fuzz target.
TARGET_EXTS = {
    "fuzz_pcx": {".pcx"},
    "fuzz_wal": {".wal", ".m8", ".m32"},
    "fuzz_stb": {".tga", ".png", ".jpg", ".jpeg", ".pcx", ".wal"},
    "fuzz_models": {".md2", ".mdl", ".md3", ".sp2", ".dkm", ".fm"},
}

MAX_FILE = 8 * 1024 * 1024
PAK_HEADER_SIZE = 12
PAK_DIR_RECORD_SIZE = 64


def pak_entries(path):
    """Yield (name, offset, size) for a (Yamagi variant) Quake 2 PAK.

    Header: ident "PACK", dirofs, dirlen, all little-endian ints
    (IDPAKHEADER in the engine's filesystem.c).  The directory is a
    plain table of 64-byte records: char name[56], int filepos,
    int filelen.
    """
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        header = f.read(PAK_HEADER_SIZE)
        if header[:4] != b"PACK":
            raise ValueError("%s: not a PAK file (magic %r)"
                    % (path, header[:4]))
        dirofs, dirlen = struct.unpack("<II", header[4:12])
        if dirofs + dirlen > size:
            raise ValueError("%s: directory outside file" % path)
        f.seek(dirofs)
        table = f.read(dirlen)
    for i in range(0, len(table) - len(table) % PAK_DIR_RECORD_SIZE,
            PAK_DIR_RECORD_SIZE):
        rec = table[i:i + PAK_DIR_RECORD_SIZE]
        name = rec[:56].split(b"\0")[0]
        if not name:
            continue
        offset, length = struct.unpack("<II", rec[56:64])
        if 0 < length and offset + length <= dirofs:
            yield (name.decode("ascii", "replace"), offset, length)


def emit(out_base, target, tag, data):
    dst = os.path.join(out_base, target)
    os.makedirs(dst, exist_ok=True)
    with open(os.path.join(dst, tag), "wb") as o:
        o.write(data)


def collect_paks(src, out_base):
    paks = sorted(
        os.path.join(dp, fn)
        for dp, _, fns in os.walk(src)
        for fn in fns if fn.endswith(".pak")
    )
    for pak in paks:
        base = os.path.splitext(os.path.basename(pak))[0]
        with open(pak, "rb") as f:
            for name, off, length in pak_entries(pak):
                ext = os.path.splitext(name)[1].lower()
                if length > MAX_FILE:
                    continue
                f.seek(off)
                data = f.read(length)
                safe = "%s_%s" % (base, name.replace("/", "_"))
                for target, exts in TARGET_EXTS.items():
                    if ext in exts:
                        emit(out_base, target, safe, data)


def collect_loose(src, out_base):
    for dp, _, fns in os.walk(src):
        for fn in fns:
            ext = os.path.splitext(fn)[1].lower()
            for target, exts in TARGET_EXTS.items():
                if ext not in exts:
                    continue
                full = os.path.join(dp, fn)
                try:
                    if os.path.getsize(full) > MAX_FILE:
                        continue
                    with open(full, "rb") as o:
                        data = o.read()
                except OSError:
                    continue
                safe = "loose_" + os.path.relpath(full, src)
                emit(out_base, target, safe.replace("/", "_"), data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", action="append", default=None,
            help="game dir to scan (default: the yquake2 build tree)")
    ap.add_argument("--out", default="corpus")
    args = ap.parse_args()

    default_src = "/Volumes/Scratch/dev/quake2/yquake2/build-sdl3/release"
    srcs = args.src or [default_src]

    here = os.path.dirname(os.path.abspath(__file__))
    out_base = (args.out if os.path.isabs(args.out)
            else os.path.join(here, args.out))

    for src in srcs:
        if not os.path.isdir(src):
            print("skip missing source: %s" % src, file=sys.stderr)
            continue
        collect_paks(src, out_base)
        collect_loose(src, out_base)

    for target in sorted(TARGET_EXTS):
        d = os.path.join(out_base, target)
        n = len(os.listdir(d)) if os.path.isdir(d) else 0
        print("%-14s %5d seeds" % (target, n))


if __name__ == "__main__":
    main()
