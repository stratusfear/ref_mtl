#!/usr/bin/env python3
"""Hostile BSP generator (round-18 Z9 tooling).

Writes crafted maps for the ref_mtl loader regressions found by the
external audit (rounds 18: Z5, Z6 lightgrid/DECOUPLED_LM, Z7) into
<out>/baseq2/maps/.  Every input is a mutation of base1.bsp extracted
from the game paks, so only the broken field differs from a map that
is known to load.  Nothing here is ever loaded by fix_verify.sh; run
them through tools/hostile/run_hostile.py.

usage: mkbsp.py --datadir <dir with baseq2/pak0.pak> --out <scratch game dir>
requires: python3 (stdlib only)
"""
import argparse, os, struct, zlib  # noqa: F401  (zlib kept for pak parity)

HEADER_LUMPS = 19
L = dict(ENT=0, PLANES=1, VERTS=2, VIS=3, NODES=4, TEXINFO=5, FACES=6,
         LIGHT=7, LEAFS=8, LEAFFACES=9, EDGES=11, SURFEDGES=12, MODELS=13)


def pak_extract(datadir, want):
    """Return the bytes of `want` (lowercase path) from baseq2/pak*.pak."""
    for i in range(9):
        for name in (f"pak{i}.pak",):
            p = os.path.join(datadir, "baseq2", name)
            if not os.path.exists(p):
                continue
            d = open(p, "rb").read()
            if d[:4] != b"PACK":
                continue
            diroff, dirlen = struct.unpack_from("<2i", d, 4)
            for k in range(dirlen // 64):
                base = diroff + 64 * k
                ofs, ln = struct.unpack_from("<2i", d, base + 56)
                fn = d[base:base + 56].split(b"\0")[0].decode("latin1").lower()
                if fn == want:
                    return d[ofs:ofs + ln]
    raise SystemExit(f"{want} not found under {datadir}/baseq2/pak*.pak")


def lump(d, i):
    return struct.unpack_from("<ii", d, 8 + 8 * i)


def setlump(d, i, o, l):
    struct.pack_into("<ii", d, 8 + 8 * i, o, l)


def faces(d):
    o, l = lump(d, L["FACES"])
    return [(o + 20 * k) for k in range(l // 20)]


def texflags(d, ti):
    o, l = lump(d, L["TEXINFO"])
    return struct.unpack_from("<i", d, o + 76 * ti + 32)[0]


def face_lit(d, fo):
    ti = struct.unpack_from("<h", d, fo + 10)[0]
    # exclude sky, warp, trans33, trans66
    return not (texflags(d, ti) & (0x4 | 0x8 | 0x10 | 0x20))


def add_bspx(d, lumps):
    end = len(d)
    pad = (-end) % 4
    d += b"\0" * pad
    hdr = len(d)
    d += struct.pack("<4si", b"BSPX", len(lumps))
    data_ofs = len(d) + 32 * len(lumps)
    table = b""
    blob = b""
    for n, payload in lumps:
        table += struct.pack("<24sii", n.encode(), data_ofs + len(blob), len(payload))
        blob += payload
    d += table + blob
    return d


def rewrite_entities(d, key, value):
    """Replace the worldspawn key's value; keeps every lump valid in the file."""
    eo, el = lump(d, L["ENT"])
    ent = bytearray(d[eo:eo + el])
    text = ent.decode("latin1")
    import re
    m = re.search('"key"[^"]*"[^"]*"'.replace("key", re.escape(key)), text)
    if m:
        text = text[:m.start()] + '"%s" "%s"' % (key, value) + text[m.end():]
    else:
        i = text.index("{") + 1
        text = text[:i] + '"%s" "%s" ' % (key, value) + text[i:]
    nb = text.encode("latin1")
    delta = len(nb) - el
    for i in range(HEADER_LUMPS):  # shift only lumps physically after entities
        o, l = lump(d, i)
        if i != L["ENT"] and o >= eo + el:
            setlump(d, i, o + delta, l)
    return bytearray(bytes(d[:8 + HEADER_LUMPS * 8]) + d[8 + HEADER_LUMPS * 8:eo] + nb + d[eo + el:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--datadir", required=True, help="game data dir holding baseq2/pak0.pak")
    ap.add_argument("--out", required=True, help="scratch game dir to write <out>/baseq2/maps")
    a = ap.parse_args()
    outdir = os.path.join(a.out, "baseq2", "maps")
    os.makedirs(outdir, exist_ok=True)

    base = bytearray(pak_extract(a.datadir, "maps/base1.bsp"))
    muts = {}

    def mut(name):
        def deco(f):
            d = bytearray(base)
            f(d)
            muts[name] = d
            return f
        return deco

    @mut("b_lightlen")        # LIGHTING lump runs 64 MB past EOF (Z5a: clamped, loads)
    def _(d):
        o, l = lump(d, L["LIGHT"]); setlump(d, L["LIGHT"], o, len(d) - o + 64 * 1024 * 1024)

    @mut("b_lumpneg")         # LIGHTING lump offset -5 (Z5a: hard reject)
    def _(d):
        o, l = lump(d, L["LIGHT"]); setlump(d, L["LIGHT"], -5, 100)

    # AG2: node-tree shape (the tree the renderer's recursive walks take).
    # dnode_t: planenum +0, children[2] int at +4/+8 (negative = -(leaf+1)),
    # mins/maxs 6 shorts, firstface/numfaces at +24/+26.
    def node_at(d, i):
        return lump(d, L["NODES"])[0] + 28 * i

    def leaf_at(d, i):
        return lump(d, L["LEAFS"])[0] + 28 * i

    def leaf_solid(d, i):
        return struct.unpack_from("<i", d, leaf_at(d, i))[0] & 1  # CONTENTS_SOLID

    def append_lump(d, idx, payload):
        pad = (-len(d)) % 4
        d += b"\0" * pad + payload
        o, l = lump(d, idx)
        setlump(d, idx, len(d) - len(payload), len(payload))

    @mut("b_ag2_cycleroot")   # node 0's child[1] points back at node 0
    def _(d):
        struct.pack_into("<i", d, node_at(d, 0) + 8, 0)

    @mut("b_ag2_sharenod")    # node 2193 (node 0's other child) also becomes
                              # a child of node 1: one node, two parents
    def _(d):
        other = struct.unpack_from("<i", d, node_at(d, 0) + 8)[0]
        struct.pack_into("<i", d, node_at(d, 1) + 4, other)

    @mut("b_ag2_shareleaf")   # one NON-SOLID leaf reached by two nodes
    def _(d):
        lc = lump(d, L["LEAFS"])[1] // 28
        leaf = next(i for i in range(1, lc) if not leaf_solid(d, i))
        struct.pack_into("<i", d, node_at(d, 1) + 4, -(leaf + 1))
        struct.pack_into("<i", d, node_at(d, 2) + 4, -(leaf + 1))

    @mut("c_ag2_solidleaf")   # a SOLID leaf reached by two nodes: legal, must load
    def _(d):
        lc = lump(d, L["LEAFS"])[1] // 28
        leaf = next(i for i in range(1, lc) if leaf_solid(d, i))
        struct.pack_into("<i", d, node_at(d, 1) + 4, -(leaf + 1))
        struct.pack_into("<i", d, node_at(d, 2) + 4, -(leaf + 1))

    @mut("b_ag2_leafbig")     # leafs lump repeated 13x: 68094 records, past
                              # MAX_MAP_LEAFS (the stack arrays of Mod_LoadNodes)
    def _(d):
        o, l = lump(d, L["LEAFS"])
        append_lump(d, L["LEAFS"], d[o:o + l] * 13)

    @mut("b_lightofs")        # every lit face points at the last byte of the lighting lump
    def _(d):
        o, l = lump(d, L["LIGHT"])
        for fo in faces(d):
            if face_lit(d, fo):
                struct.pack_into("<i", d, fo + 16, l - 1)

    @mut("b_firstedge")       # first lit face's firstedge far past numsurfedges
    def _(d):
        fo = [f for f in faces(d) if face_lit(d, f)][0]
        struct.pack_into("<i", d, fo + 4, 50_000_000)

    @mut("b_surfedge")        # surfedge values far past numedges / INT_MIN
    def _(d):
        o, l = lump(d, L["SURFEDGES"])
        for k in range(0, l // 4, 2):
            struct.pack_into("<i", d, o + 4 * k, 0x7ffffff0)
        for k in range(1, l // 4, 2):
            struct.pack_into("<i", d, o + 4 * k, -0x80000000)

    @mut("b_edgevert")        # edge vertex indices 0xffff (numvertexes ~10k)
    def _(d):
        o, l = lump(d, L["EDGES"])
        for k in range(l // 4):
            struct.pack_into("<HH", d, o + 4 * k, 0xffff, 0xfffe)

    @mut("b_zeroedges")       # one face with numedges 0
    def _(d):
        fo = faces(d)[100]
        struct.pack_into("<h", d, fo + 8, 0)

    @mut("b_warp1000")        # a warped face with 1000 edges (Z7)
    def _(d):
        for fo in faces(d):
            ti = struct.unpack_from("<h", d, fo + 10)[0]
            if texflags(d, ti) & 0x8:
                struct.pack_into("<ih", d, fo + 4, 0, 1000)
                break
        else:
            raise SystemExit("no warp face in base1")

    @mut("b_lit1000")         # a lit face with 1000 edges (in-range surfedges)
    def _(d):
        fo = [f for f in faces(d) if face_lit(d, f)][0]
        struct.pack_into("<ih", d, fo + 4, 0, 1000)

    @mut("b_numclusters")     # vis numclusters 0x08000000 (lump stays ~200 KB)
    def _(d):
        o, l = lump(d, L["VIS"])
        struct.pack_into("<i", d, o, 0x08000000)

    @mut("b_texcycle")        # texinfo animation chain 0->1->2->1 (never returns to 0)
    def _(d):
        o, l = lump(d, L["TEXINFO"])
        for ti, nx in ((0, 1), (1, 2), (2, 1)):
            struct.pack_into("<i", d, o + 76 * ti + 72, nx)

    @mut("b_texnext")         # texinfo nexttexinfo far past numtexinfo
    def _(d):
        o, l = lump(d, L["TEXINFO"])
        struct.pack_into("<i", d, o + 72, 10_000_000)

    @mut("b_submodel")        # inline models *1.. point at faces far past numfaces
    def _(d):
        o, l = lump(d, L["MODELS"])
        for k in range(1, l // 48):
            struct.pack_into("<ii", d, o + 48 * k + 40, 5_000_000, 50)

    @mut("b_notex")           # texinfo 0 names a texture that does not exist
    def _(d):
        o, l = lump(d, L["TEXINFO"])
        d[o + 40:o + 72] = b"evil/doesnotexist".ljust(32, b"\0")

    # AG1: node surface range vs the surface array
    # dnode_t: firstface at +24, numfaces at +26 (unsigned short), 28-byte records
    def node0(d):
        return lump(d, L["NODES"])[0]

    @mut("b_ag1_wide")        # node 0: firstface 65535 / numfaces 65535 (the af0176 mutation)
    def _(d):
        struct.pack_into("<HH", d, node0(d) + 24, 0xffff, 0xffff)

    @mut("b_ag1_edgeeq")      # node 0 range ends exactly at numfaces: must load
    def _(d):
        n = lump(d, L["FACES"])[1] // 20
        struct.pack_into("<HH", d, node0(d) + 24, n - 1, 1)

    @mut("b_ag1_edgeover")    # node 0 range ends one past numfaces: must reject
    def _(d):
        n = lump(d, L["FACES"])[1] // 20
        struct.pack_into("<HH", d, node0(d) + 24, n - 1, 2)

    @mut("b_lgrid_neg")       # LIGHTGRID_OCTREE: numnodes chosen so ctx.ofs wraps negative
    def _(d):
        p = (struct.pack("<3f", 8, 8, 8) + struct.pack("<3i", 1, 1, 1)
             + struct.pack("<3f", 0, 0, 0) + b"\x01"
             + struct.pack("<ii", 0, 91625968) + b"\0" * 64)
        return add_bspx(d, [("LIGHTGRID_OCTREE", p)])

    @mut("b_lgrid_hang")      # LIGHTGRID_OCTREE: numleafs 0xffffffff, tiny lump
    def _(d):
        p = (struct.pack("<3f", 8, 8, 8) + struct.pack("<3i", 1, 1, 1)
             + struct.pack("<3f", 0, 0, 0) + b"\x01"
             + struct.pack("<ii", 0, 0) + struct.pack("<I", 0xffffffff))
        return add_bspx(d, [("LIGHTGRID_OCTREE", p)])

    @mut("b_declm_big")       # DECOUPLED_LM: 65535x65535 lightmaps for every face
    def _(d):
        n = len(faces(d))
        p = b"".join(struct.pack("<HHi8f", 65535, 65535, 0, 1, 0, 0, 0, 0, 1, 0, 0)
                     for _ in range(n))
        return add_bspx(d, [("DECOUPLED_LM", p)])

    @mut("b_declm_ofs")       # DECOUPLED_LM: sane 4x4 lightmaps, lightofs past the lump
    def _(d):
        n = len(faces(d))
        p = b"".join(struct.pack("<HHi8f", 4, 4, 0x7fffff00, 1, 0, 0, 0, 0, 1, 0, 0)
                     for _ in range(n))
        return add_bspx(d, [("DECOUPLED_LM", p)])

    @mut("b_extents")         # lit face texinfo scaled so the surface extent is enormous
    def _(d):
        fo = [f for f in faces(d) if face_lit(d, f)][0]
        ti = struct.unpack_from("<h", d, fo + 10)[0]
        o, l = lump(d, L["TEXINFO"])
        struct.pack_into("<4f", d, o + 76 * ti, 1000.0, 0, 0, 0)

    @mut("b_trunc")           # 152-byte header only: every lump offset is past EOF
    def _(d):
        del d[152:]

    # --- second batch
    muts2 = {}

    def mut2(name):
        def deco(f):
            d = bytearray(base)
            f(d)
            muts2[name] = d
            return f
        return deco

    @mut2("b_lightofs_big")   # every face lightofs 0x7fff0000
    def _(d):
        for fo in faces(d):
            struct.pack_into("<i", d, fo + 16, 0x7fff0000)

    @mut2("b_lightlen_small") # LIGHTING lump runs 4 KB past EOF
    def _(d):
        o, l = lump(d, L["LIGHT"]); setlump(d, L["LIGHT"], o, len(d) - o + 4096)

    @mut2("b_vertlen")        # VERTEXES lump runs 4 KB past EOF
    def _(d):
        o, l = lump(d, L["VERTS"])
        setlump(d, L["VERTS"], len(d) - 12 * 10, 12 * 10 + 4092)

    @mut2("b_cluster")        # every leaf cluster 30000 (vis lump has ~1k clusters)
    def _(d):
        o, l = lump(d, L["LEAFS"])
        for k in range(l // 28):
            c = struct.unpack_from("<h", d, o + 28 * k + 4)[0]
            if c != -1:
                struct.pack_into("<h", d, o + 28 * k + 4, 30000)

    # --- texture batch: texinfo 0..7 name a hostile texture under textures/evil/
    muts3 = {}
    for t in ["w_wide", "w_zero", "w_badofs", "w_negofs", "m_wrap", "m_ok"]:
        def f(d, t=t):
            o, l = lump(d, L["TEXINFO"])
            for ti in range(8):
                d[o + 76 * ti + 40:o + 76 * ti + 72] = ("evil/" + t).encode().ljust(32, b"\0")
        mut2("b_tex_" + t)(f)

    # --- sky-name probes (Z8): worldspawn sky key rewritten
    muts4 = {}
    for name, sky in (("b_skysmall", "zz"),
                      ("b_sky63", ("skycover" + "".join("%02d" % (i % 100) for i in range(1, 40)))[:62] + "z")):
        d = rewrite_entities(bytearray(base), "sky", sky)
        assert len(sky) in (2, 63)
        muts4[name] = d

    for batch in (muts, muts2, muts3, muts4):
        for n, d in batch.items():
            open(os.path.join(outdir, n + ".bsp"), "wb").write(bytes(d))
        print(" ".join(batch))


if __name__ == "__main__":
    main()
