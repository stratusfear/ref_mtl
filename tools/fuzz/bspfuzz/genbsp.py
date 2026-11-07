#!/usr/bin/env python3
"""AE3: mutate shipped BSPs for the batched host fallback.

Mod_LoadBrushModel (and its lump loaders) live in mtl_model.m and
pull in the renderer/Metal context, so they did not link into the
AE1 libFuzzer harness.  AE3's fallback feeds mutated maps through
the real game host instead; this script is the mutator half.

Mutation weights follow the AE3 brief: the lump directory (the 19
lump_t offset/length pairs after the 8-byte header) gets 60% of the
mutations, count/size fields inside the lumps 25%, raw bytes 10%,
and the header version word 5%.  That is where the earlier rounds'
BSP bugs (Z4, Z5a-h) were.

Output: one .bsp per requested mutant, named af<index>.bsp, plus a
manifest TSV recording base map and the mutation applied, so any
finding maps straight back to its recipe.  Deterministic per seed.
"""

import argparse
import os
import random
import struct
import sys

PAK_HEADER_SIZE = 8 + 3 * 4
PAK_DIR_RECORD_SIZE = 64

# Quake 2 BSP idents: legacy (ident 10, version 2) and the Yamagi
# recompiled shipped maps ("IBSP" little-endian, version 38; see
# IDBSPHEADER in the engine's files.h).  Header layout is the same
# either way: ident, version, 19 lump_t offset/length pairs.
BSP_IDENTS = (0x0000000A, 0x50534249)
NUM_LUMPS = 19
HEADER_SIZE = 8 + NUM_LUMPS * 8

# Lump names in header order, matching the LUMP_* defines in the
# engine's files.h (Quake 2 layout).
LUMP_NAMES = [
    "entities", "planes", "vertexes", "visibility", "nodes", "texinfo",
    "faces", "lighting", "leafs", "leaffaces", "leafbrushes", "edges",
    "surfedges", "models", "brushes", "brushsides", "pop", "areas",
    "areaportals",
]

# Mutations tried with equal weight on a targeted 4-byte field.
FIELD_VALUES = [0, 1, 2, 0x7FFFFFFF, 0xFFFFFFFF, 0x00FFFFFF]


def pak_entries(path):
    """Yield (name, offset, size); same Yamagi PAK layout as
    tools/fuzz/mkseedcorpus.py (PACK, dirofs, dirlen, 64-byte records)."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        header = f.read(PAK_HEADER_SIZE)
        if header[:4] != b"PACK":
            raise ValueError("%s: not a PAK file" % path)
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


def collect_maps(datadir):
    """All maps/*.bsp from every pak*.pak in datadir/baseq2 and the
    loose datadir/baseq2/maps.  Returns {name: bytes}."""
    base = os.path.join(datadir, "baseq2")
    maps = {}
    paks = sorted(os.path.join(base, fn) for fn in os.listdir(base)
            if fn.endswith(".pak"))
    for pak in paks:
        with open(pak, "rb") as f:
            for name, off, length in pak_entries(pak):
                low = name.lower()
                if low.endswith(".bsp") and low.startswith("maps"):
                    f.seek(off)
                    data = f.read(length)
                    if len(data) >= HEADER_SIZE and \
                            struct.unpack("<II", data[:8])[0] in BSP_IDENTS:
                        maps[os.path.basename(low)] = data
    loosedir = os.path.join(base, "maps")
    if os.path.isdir(loosedir):
        for fn in os.listdir(loosedir):
            if fn.lower().endswith(".bsp"):
                with open(os.path.join(loosedir, fn), "rb") as f:
                    data = f.read()
                if len(data) >= HEADER_SIZE and \
                        struct.unpack("<II", data[:8])[0] in BSP_IDENTS:
                    maps[fn.lower()] = data
    return maps


def mutate(buf, rng, kind):
    """Return (mutated_bytes, description) for one weighted mutation."""
    data = bytearray(buf)

    if kind == "version":
        old, = struct.unpack_from("<I", data, 4)
        new = rng.choice([0, 1, 3, 11, 0xFFFFFFFF])
        struct.pack_into("<I", data, 4, new)
        return bytes(data), "version %d -> %d" % (old, new)

    if kind == "lumpdir":
        lump = rng.randrange(NUM_LUMPS)
        which = rng.choice(["ofs", "len"])
        at = 8 + lump * 8 + (0 if which == "ofs" else 4)
        old, = struct.unpack_from("<I", data, at)
        if which == "ofs":
            new = rng.choice(FIELD_VALUES + [
                rng.randrange(len(data) + 1),
                rng.randrange(1 << 24)])
        else:
            new = rng.choice(FIELD_VALUES + [
                rng.randrange(len(data) + 1),
                (old + rng.choice([1, -1, 8, -8])) & 0xFFFFFFFF])
        struct.pack_into("<I", data, at, new)
        return bytes(data), "lump %s (%s) -> %d (was %d)" % (
                LUMP_NAMES[lump].lower(), which, new, old)

    if kind == "lumpcount":
        # Pick a non-empty lump, then rewrite one in-lump 4-byte field
        # near the lump start: that is where these lumps keep their
        # leading indices/counts (face types, numedges, model counts).
        candidates = [i for i in range(NUM_LUMPS)
                if struct.unpack_from("<I", data, 8 + i * 8 + 4)[0] > 0]
        if not candidates:
            return mutate(buf, rng, "lumpdir")
        lump = rng.choice(candidates)
        ofs, ln = struct.unpack_from("<II", data, 8 + lump * 8)
        span = min(ln, 64)
        if ofs + span > len(data):
            return mutate(buf, rng, "lumpdir")
        at = ofs + rng.randrange(0, span, 4)
        old, = struct.unpack_from("<I", data, at)
        new = rng.choice(FIELD_VALUES + [rng.randrange(1 << 20)])
        struct.pack_into("<I", data, at, new)
        return bytes(data), "lump %s word@%d -> %d (was %d)" % (
                LUMP_NAMES[lump].lower(), at - ofs, new, old)

    # raw
    at = rng.randrange(len(data))
    old = data[at]
    data[at] = rng.randrange(256)
    return bytes(data), "byte@%d: %d -> %d" % (at, old, data[at])


def pick_kind(rng):
    return rng.choices(
            ["lumpdir", "lumpcount", "raw", "version"],
            weights=[60, 25, 10, 5])[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--datadir", required=True,
            help="dir holding baseq2/pak0.pak (the shipped datadir)")
    ap.add_argument("--out", required=True, help="staging dir for af*.bsp")
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    maps = collect_maps(args.datadir)
    if not maps:
        print("no BSP maps found under %s" % args.datadir, file=sys.stderr)
        return 1
    names = sorted(maps)
    os.makedirs(args.out, exist_ok=True)

    rng = random.Random(args.seed)
    with open(os.path.join(args.out, "MANIFEST.tsv"), "w") as man:
        man.write("map\tbase\tkind\tmutation\n")
        for i in range(args.count):
            base = names[i % len(names)]
            kind = pick_kind(rng)
            data, desc = mutate(maps[base], rng, kind)
            name = "af%04d" % i
            with open(os.path.join(args.out, name + ".bsp"), "wb") as f:
                f.write(data)
            man.write("%s\t%s\t%s\t%s\n" % (name, base, kind, desc))
    print("%d mutants over %d base maps -> %s" % (args.count, len(names),
            args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
