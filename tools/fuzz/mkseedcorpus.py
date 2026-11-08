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

AF2 additions: well-formed DKM v1/v2, flex .fm and MDL seeds are
synthesised via tools/hostile/mkimg.py (no shipped pak carries those
formats).  AF2 also quarantined a fuzz_stb TGA "bomb" by sha1; AH1
retired that entry - the shape is now refused before stb allocates
(stb.c LoadSTB caps), and a round-25 re-scan of the corpora sources
(10 paks plus every loose image under the game data dirs, via
tools/hostile/scan_img.py) could not find the file in any source, so
the quarantine's "shipped texture" label was no longer verifiable.
AH1 instead feeds the exact regression inputs (the 34-byte timeout
artifact and its PNG/JPEG siblings) as SYNTH_TARGETS seeds.

Usage: python3 mkseedcorpus.py [--src DIR ...] [--out DIR]
"""

import argparse
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

# Extension sets per fuzz target.
TARGET_EXTS = {
    "fuzz_pcx": {".pcx"},
    "fuzz_wal": {".wal", ".m8", ".m32"},
    "fuzz_stb": {".tga", ".png", ".jpg", ".jpeg", ".pcx", ".wal"},
    "fuzz_models": {".md2", ".mdl", ".md3", ".sp2", ".dkm", ".fm"},
}

# AH1: the pre-decode caps in LoadSTB (src/files/stb.c) make the
# AF2.3 quarantine moot - the TGA-bomb shape is refused with a reason
# line before any canvas is allocated.  A round-25 re-scan
# (tools/hostile/scan_img.py, 10 paks + every loose image under the
# game data dirs) found no such image in any shipped texture, so the
# file's "real shipped texture" label could not be re-verified - AI4
# visible correction: an earlier form of this comment said the file
# was not found "in any corpus source", which was wrong: it is on
# disk in tools/fuzz/crashers/ (libFuzzer copy, name = its sha1, 63
# bytes).  Not shipped content, but present, and now measured: the
# cap refuses it and the native (no-asan) cost of the uncapped shape
# is ~5.7 s on a ~1.37 GB canvas, ended by stb's own guard.  The
# dictionary machinery is kept for the next such input; the AF2 entry
# is gone (see the module docstring).
QUARANTINE_SHA1 = {}

# AF2.2: fuzz_models has nothing to teach it DKM, flex or MDL: no
# shipped pak contains a .dkm, a .fm or a .mdl (AB1 scan), so the
# pak-derived corpus never reaches those loaders past their ident
# dispatch.  Hand-build one valid seed per format, reusing the
# round-18 Z9 builder in tools/hostile/mkimg.py (the AF1 controls
# and the c_flex/c_mdl controls are exactly those well-formed files).

# AH1.2: pin the fixed shapes in the corpus so a future regression
# replays them.  tools/hostile/mkimg.py builds these; the .tga is
# byte-identical to the fuzz_stb timeout artifact (sha1 35106c89..)
# that ended AF2's report-only stance, the PNG/JPEG siblings are the
# same 27164x26480 claim in the other two header formats LoadSTB
# reads, and synth_stb_sideover sits one pixel past the side cap.
# (The pixel-product cap's sibling, 4097x4096, is a strict subset of
# what the 27164x26480 seed already exercises, so it is not seeded.)
SYNTH_TARGETS = {
    "fuzz_models/synth_dkm_v2.md2": "staging/af1_dkm_okv2.md2",
    "fuzz_models/synth_dkm_v1.md2": "staging/af1_dkm_okv1.md2",
    "fuzz_models/synth_flex.fm":    "staging/c_flex.fm",
    "fuzz_models/synth_mdl.md2":    "staging/c_mdl.md2",
    "fuzz_stb/synth_stb_tgabomb.tga":  "players/male/t_bomb.tga",
    "fuzz_stb/synth_stb_bomb.png":     "players/male/t_bombpng.png",
    "fuzz_stb/synth_stb_bomb.jpg":     "players/male/t_bombjpg.jpg",
    "fuzz_stb/synth_stb_sideover.tga": "players/male/t_sideover.tga",
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
    digest = hashlib.sha1(data).hexdigest()
    reason = QUARANTINE_SHA1.get(digest)
    if reason:
        print("quarantined %s/%s: %s" % (target, tag, reason),
                file=sys.stderr)
        return
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


def synth_models(out_base, datadir):
    """AF2.2: DKM v1/v2, flex .fm and MDL seeds for fuzz_models.

    AH1.2 adds the four fuzz_stb size-cap regression seeds through
    the same path; the SYNTH_TARGETS table names what is copied.

    tools/hostile/mkimg.py (round-18 Z9) already hand-builds exactly
    these as its well-formed controls (the AF1 DKM controls plus the
    c_flex/c_mdl controls), built from the real pak sections.  Run it
    into a scratch dir and copy the four files into the corpus."""
    here = os.path.dirname(os.path.abspath(__file__))
    mkimg = os.path.join(here, "..", "hostile", "mkimg.py")
    with tempfile.TemporaryDirectory() as td:
        subprocess.run([sys.executable, mkimg,
                "--datadir", datadir, "--out", td], check=True)
        for dst, srcrel in SYNTH_TARGETS.items():
            with open(os.path.join(td, "baseq2", srcrel), "rb") as f:
                data = f.read()
            target, tag = dst.split("/", 1)
            emit(out_base, target, tag, data)


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

    synth_models(out_base, srcs[0] if srcs else default_src)

    for target in sorted(TARGET_EXTS):
        d = os.path.join(out_base, target)
        n = len(os.listdir(d)) if os.path.isdir(d) else 0
        print("%-14s %5d seeds" % (target, n))


if __name__ == "__main__":
    main()
