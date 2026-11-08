#!/usr/bin/env python3
"""AG2 seed + shape corpus for tools/fuzz/fuzz_nodes.c (round-24).

Writes, into --out (default <fuzz dir>/corpus/fuzz_nodes):

  seed_<map>.bin    one shipped BSP's nodes lump with the counts the
                    harness header wants: numplanes, numleafs,
                    numsurfaces (LE dwords), then the dnode_t records.
                    This is the "shipped data is a tree" baseline.
  p_*.bin           the AG2 shapes, as the harness' input format:
                    cycle at the root, self-child, shared node (DAG),
                    exponential double-child chain, a leaf index past
                    MAX_MAP_LEAFS, a node lump past MAX_MAP_NODES, and
                    deep chains of a given depth (the depth-blowup
                    measurement).  AH2 adds the zero end of the node
                    count: p_count_zero (the exact 12-byte artifact:
                    counts 0/0/0, empty lump), p_count_one (the
                    smallest tree that must still load), and the zero
                    neighbours p_numleafs_zero / p_numplanes_zero
                    (count 1 with empty leafs/planes arrays; both
                    already drop at the record-loop range checks).

usage: nodesseeds.py [--datadir DIR] [--out DIR] [--depths 20000,100000,1000000]
requires: python3 (stdlib only)
"""
import argparse, os, struct

IDENT = 0x50534249
BSPVERSION = 38
L = dict(PLANES=1, VIS=3, NODES=4, FACES=6, LEAFS=8, MODELS=13)
DSIZE = 28
LSIZE = 28
HEADER_LUMPS = 19


def shipped_maps(datadir):
    root = os.path.join(datadir, "baseq2")
    for i in range(9):
        p = os.path.join(root, "pak%d.pak" % i)
        if not os.path.exists(p):
            continue
        d = open(p, "rb").read()
        if d[:4] != b"PACK":
            continue
        doff, dlen = struct.unpack_from("<2i", d, 4)
        for k in range(dlen // 64):
            b = doff + 64 * k
            name = d[b:b + 56].split(b"\0")[0].decode("ascii", "replace").lower()
            off, size = struct.unpack_from("<2i", d, b + 56)
            if name.endswith(".bsp"):
                yield name, d[off:off + size]


def lump(d, i):
    return struct.unpack_from("<2i", d, 8 + i * 8)


def header(numplanes, numleafs, numsurfaces):
    return struct.pack("<3i", numplanes, numleafs, numsurfaces)


def node(planenum, c0, c1, firstface=0, numfaces=0):
    return struct.pack("<3i6h2H", planenum, c0, c1, 0, 0, 0, 0, 0, 0,
                       firstface, numfaces)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--datadir", default="/Volumes/Scratch/dev/quake2/Quake 2.app/"
                    "Contents/Resources")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                  "corpus", "fuzz_nodes"))
    ap.add_argument("--depths", default="")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    n = 0
    for name, d in shipped_maps(a.datadir):
        if len(d) < 8 + HEADER_LUMPS * 8:
            continue
        if struct.unpack_from("<2i", d, 0) != (IDENT, BSPVERSION):
            continue
        no, nl = lump(d, L["NODES"])
        lo, ll = lump(d, L["LEAFS"])
        po, pl = lump(d, L["PLANES"])
        fo, fl = lump(d, L["FACES"])
        if min(no, nl, lo, ll) < 0 or nl % DSIZE or ll % LSIZE:
            continue
        payload = header(pl // 12, ll // LSIZE, fl // 20) + d[no:no + nl]
        open(os.path.join(a.out, "seed_%s.bin" % os.path.basename(name)), "wb").write(payload)
        n += 1

    # cycle: the root's own child points back at the root
    open(os.path.join(a.out, "p_cycle_root.bin"), "wb").write(
        header(1, 1, 0) + node(0, 1, 0) + node(0, -1, -1))
    # self-child (the reviewer's probe shape, in harness form)
    open(os.path.join(a.out, "p_cycle_self.bin"), "wb").write(
        header(1, 1, 0) + node(0, 0, -1))
    # shared node: two different parents reach node 2
    open(os.path.join(a.out, "p_share_node.bin"), "wb").write(
        header(1, 2, 0) + node(0, 1, 2) + node(0, -1, -1) + node(0, -1, 1))
    # shared non-solid leaf: nodes 1 and 2 both reach leaf 1
    open(os.path.join(a.out, "p_share_leaf.bin"), "wb").write(
        header(1, 2, 0) + node(0, 1, 2) + node(0, -1, -2) + node(0, -2, -1))
    # exponential: k nodes, each with the same NON-SOLID leaf (leaf 1) in
    # both children of the last record, and each node duplicated by its
    # parent, so the leaf is reached 2^k times
    k = 20
    body = b"".join(node(0, i + 1, i + 1) for i in range(k)) + node(0, -2, -2)
    open(os.path.join(a.out, "p_dag_double.bin"), "wb").write(header(1, 2, 0) + body)
    # leaf index just past MAX_MAP_LEAFS, with a leafs lump big enough for it
    bigleafs = 65537
    open(os.path.join(a.out, "p_leaf_past_max.bin"), "wb").write(
        header(1, bigleafs, 0) + node(0, -bigleafs, -1))
    # AH2: the zero end of the node-count division.  p_count_zero is
    # the exact 12-byte reproduction input (counts 0/0/0, empty
    # lump); before the Mod_LoadNodes count<1 reject it died with a UBSan
    # pointer-index report inside Mod_NumberLeafs.  p_count_one is
    # the smallest tree that must still load (solid leaf 0 on one
    # side, non-solid leaf 1 on the other).  The zero neighbours
    # already dropped at the record-loop checks before AH2, and are
    # pinned here so they stay ERR_DROP-only.
    open(os.path.join(a.out, "p_count_zero.bin"), "wb").write(header(0, 0, 0))
    open(os.path.join(a.out, "p_count_one.bin"), "wb").write(
        header(1, 2, 0) + node(0, -1, -2))
    open(os.path.join(a.out, "p_numleafs_zero.bin"), "wb").write(
        header(1, 0, 0) + node(0, -1, -1))
    open(os.path.join(a.out, "p_numplanes_zero.bin"), "wb").write(
        header(0, 1, 0) + node(0, -1, -1))

    # chains that go down child[0] with the SOLID leaf 0 hanging off
    # child[1] (legal: leaf 0 is the shared content filler, and it has no
    # children of its own), so the only thing being probed is the depth of
    # the tree: one legal deep tree inside both caps (the control that must
    # still load), one past MAX_MAP_NODES, and the -N depths on the command
    # line (the pre-fix stack-overflow measurement)
    for dep, tag in ((32768, "ok"), (65537, "over_cap")):
        body = b"".join(node(0, i + 1, -1) for i in range(dep)) + node(0, -1, -1)
        open(os.path.join(a.out, "p_chain_%s.bin" % tag), "wb").write(
            header(1, 2, 0) + body)

    for dep in [int(x) for x in a.depths.split(",") if x.strip()]:
        body = b"".join(node(0, i + 1, -1) for i in range(dep)) + node(0, -1, -1)
        open(os.path.join(a.out, "p_deep_%d.bin" % dep), "wb").write(
            header(1, 2, 0) + body)

    print("seeds: %d, shapes written to %s" % (n, a.out))


main()
