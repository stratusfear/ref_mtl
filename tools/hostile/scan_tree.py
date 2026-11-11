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

"""AG2 measurement: node-tree SHAPE of every shipped BSP (round-24).

AG2's claim is about the renderer's two recursive walks over the node
tree - Mod_SetParent (models.c:2035) and Mod_NumberLeafs (models.c:2053)
- which have no depth bound and no visited marking, while Mod_LoadNodes
only checks that each child index is in range.  To choose the least
strict rule the shipped set allows, this tool measures, per map:

  - node and leaf counts (the loader's own lump clamps are applied);
  - what the renderer actually walks: from node 0 (Mod_SetParent/
    Mod_NumberLeafs start at *nodes == node 0).  Submodel headnodes are
    measured separately because the renderer never walks them
    (dmodel_t's comment: "submodels just draw faces without walking
    the bsp tree"); the game side does;
  - node references: how many parents each node has, and how many
    nodes a root walk visits more than once (a "DAG" or a cycle);
  - leaf references, split into solid (contents & CONTENTS_SOLID, the
    legal shared leaf) and non-solid;
  - the deepest chain from a root (recursion depth the loader pays);
  - cycles, detected as a parent chain longer than the node count in a
    structure where every node has at most one parent, or as a re-visit
    during the walk (which is what the renderer's recursion would pay).

usage: scan_tree.py [--datadir DIR ...]     (default: the shipped tree)
requires: python3 (stdlib only); reads pak0..8.pak and loose maps/*.bsp
"""
import argparse, os, struct

IDENT = 0x50534249        # 'IBSP'
BSPVERSION = 38           # src/common/header/files.h:337
LUMP_NODES, LUMP_LEAFS, LUMP_MODELS = 4, 8, 13
DSIZE = 28                # dnode_t: planenum, children[2], mins[3], maxs[3],
                          # firstface, numfaces (unsigned short at +24/+26)
LSIZE = 28                # dleaf_t: contents, cluster, area, mins/maxs, ranges
MSIZE = 12 * 4            # dmodel_t: mins,maxs,origin,headnode,firstface,numfaces
CONTENTS_SOLID = 1
HEADER_LUMPS = 19


def lump(d, i):
    if i >= HEADER_LUMPS:
        return (0, 0)
    return struct.unpack_from("<2i", d, 8 + i * 8)


def walk(d, no, ncount, lo, lcount, root, stats, name, depth0=0):
    """Iterative walk of one node tree.  Returns (visits, maxdepth) and
    records shared references.  A work cap catches cycles: a finite tree
    of ncount nodes cannot produce more than ncount node visits."""
    work = [(root, depth0)]
    visits = {}
    cap = 4 * ncount + 1000
    total = 0
    maxdepth = depth0
    capped = False
    while work:
        i, dep = work.pop()
        if i in visits:
            visits[i] += 1
            continue
        visits[i] = visits.get(i, 0) + 1
        total += 1
        if total > cap:
            capped = True
            break
        maxdepth = max(maxdepth, dep)
        base = no + DSIZE * i
        for j in (4, 8):
            ch = struct.unpack_from("<i", d, base + j)[0]
            if ch >= 0:
                if ch >= ncount:
                    stats["oob_node_child"].append((name, i, ch))
                    continue
                work.append((ch, dep + 1))
            else:
                ln = -1 - ch
                if ln >= lcount:
                    stats["oob_leaf_child"].append((name, i, ln))
                    continue
                stats["leafrefs"].setdefault(ln, 0)
                stats["leafrefs"][ln] += 1
    if capped:
        stats["cycle_root"].append((name, root))
    return visits, maxdepth


def analyze(name, d, stats):
    if len(d) < 8 + HEADER_LUMPS * 8:
        return
    ident, ver = struct.unpack_from("<2i", d, 0)
    if ident != IDENT or ver != BSPVERSION:
        stats["skipped_ident"].append((name, hex(ident), ver))
        return
    fs = len(d)
    no, nl = lump(d, LUMP_NODES)
    lo, ll = lump(d, LUMP_LEAFS)
    mo, ml = lump(d, LUMP_MODELS)
    if min(no, nl, lo, ll) < 0 or nl % DSIZE or ll % LSIZE:
        stats["funny_lump"].append(name)
        return
    ncount, lcount = nl // DSIZE, ll // LSIZE
    stats["maps"] += 1
    stats["nodes"] += ncount
    stats["leafs"] += lcount
    stats["max_leafs"] = max(stats["max_leafs"], lcount)
    stats["max_nodes"] = max(stats["max_nodes"], ncount)
    if stats["max_nodes"] == ncount:
        stats["max_nodes_map"] = (name, ncount)
    if lcount > 65536:
        stats["leafs_over_MAX_MAP_LEAFS"].append((name, lcount))
    if ncount == 0:
        return
    leaf_solid = [(struct.unpack_from("<i", d, lo + LSIZE * k)[0] & CONTENTS_SOLID)
                  for k in range(lcount)]

    # what the renderer walks: node 0 only
    stats["leafrefs"] = {}
    visits, depth = walk(d, no, ncount, lo, lcount, 0, stats, name)
    stats["max_depth"] = max(stats["max_depth"], depth)
    shared = [k for k, v in visits.items() if v > 1]
    if shared:
        stats["rootwalk_shared_nodes"].append((name, shared[:6], len(shared)))
    nonsolid = [ln for ln, v in stats["leafrefs"].items()
                if v > 1 and not leaf_solid[ln]]
    solid = [ln for ln, v in stats["leafrefs"].items()
             if v > 1 and leaf_solid[ln]]
    if nonsolid:
        stats["rootwalk_shared_nonsolid_leafs"].append(
            (name, nonsolid[:6], len(nonsolid)))
    stats["shared_solid_leafrefs"] += sum(v for ln, v in stats["leafrefs"].items()
                                          if v > 1 and leaf_solid[ln])
    unreached = ncount - len(visits)

    # whole-lump edge pass: every child edge of every node record, whether
    # or not the world tree reaches it.  This is what a rule placed in
    # Mod_LoadNodes' parse loop would see, so it is the number that decides
    # how strict that rule may be.
    indeg = {}
    leafin = {}
    root0_in = 0
    oob = 0
    for i in range(ncount):
        base = no + DSIZE * i
        for j in (4, 8):
            ch = struct.unpack_from("<i", d, base + j)[0]
            if ch >= 0:
                if ch >= ncount:
                    oob += 1
                    continue
                indeg[ch] = indeg.get(ch, 0) + 1
                if ch == 0:
                    root0_in += 1
            else:
                ln = -1 - ch
                if ln >= lcount:
                    oob += 1
                    continue
                leafin[ln] = leafin.get(ln, 0) + 1
    stats["wholelump_oob_children"] += oob
    stats["wholelump_shared_nodes"] += sum(1 for v in indeg.values() if v > 1)
    stats["wholelump_root_referenced"] += root0_in
    stats["wholelump_shared_nonsolid"] += sum(1 for k, v in leafin.items()
                                              if v > 1 and not leaf_solid[k])
    stats["wholelump_shared_solid"] += sum(1 for k, v in leafin.items()
                                           if v > 1 and leaf_solid[k])

    # submodel headnodes (game-side walks; the renderer does not walk them)
    if ml % MSIZE == 0:
        nm = ml // MSIZE
        for k in range(1, nm):
            head = struct.unpack_from("<i", d, mo + MSIZE * k + 24)[0]
            if head < 0 or head >= ncount:
                stats["oob_headnode"].append((name, k, head))
                continue
            v2, dep2 = walk(d, no, ncount, lo, lcount, head, stats, name)
            stats["max_depth_models"] = max(stats["max_depth_models"], dep2)
            if [x for x, c in v2.items() if c > 1]:
                stats["modelroot_shared_nodes"].append((name, k, head))
    if unreached:
        stats["nodes_not_in_world_tree"] += unreached


def _default_datadir():
    """Game data dir: $Q2_DATADIR, else the first installed Quake 2.app
    bundle found (the project-local one, then /Applications)."""
    for d in (os.environ.get("Q2_DATADIR"),
              "/Volumes/Scratch/dev/quake2/Quake 2.app/Contents/Resources",
              "/Applications/Quake 2.app/Contents/Resources"):
        if d and os.path.isdir(d):
            return d
    return "/Applications/Quake 2.app/Contents/Resources"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--datadir", action="append", default=None,
                    help="dir holding baseq2/pak*.pak and/or loose maps (repeatable)")
    a = ap.parse_args()
    roots = a.datadir or [_default_datadir(),
                          "/Volumes/Scratch/dev/quake2/yquake2/build-sdl3/release"]
    stats = {"maps": 0, "nodes": 0, "leafs": 0, "max_leafs": 0, "max_nodes": 0,
             "max_nodes_map": ("", 0), "max_depth": 0,
             "max_depth_models": 0, "skipped_ident": [], "funny_lump": [],
             "oob_node_child": [], "oob_leaf_child": [], "oob_headnode": [],
             "leafs_over_MAX_MAP_LEAFS": [], "cycle_root": [],
             "rootwalk_shared_nodes": [], "rootwalk_shared_nonsolid_leafs": [],
             "modelroot_shared_nodes": [], "shared_solid_leafrefs": 0,
             "wholelump_shared_nodes": 0, "wholelump_root_referenced": 0,
             "wholelump_shared_nonsolid": 0, "wholelump_shared_solid": 0,
             "wholelump_oob_children": 0,
             "nodes_not_in_world_tree": 0, "leafrefs": {}}
    seen = set()
    for root in roots:
        for dp, _, fns in os.walk(root):
            for fn in sorted(fns):
                p = os.path.join(dp, fn)
                low = fn.lower()
                if low.endswith(".pak"):
                    with open(p, "rb") as f:
                        data = f.read()
                    tag, doff, dlen, ver = struct.unpack_from("<4s3i", data, 0)
                    if tag != b"PACK":
                        continue
                    for k in range(dlen // 64):
                        b = doff + 64 * k
                        name = data[b:b + 56].split(b"\0")[0].decode("ascii",
                                                                     "replace").lower()
                        if not name.endswith(".bsp") or name in seen:
                            continue
                        seen.add(name)
                        off, size = struct.unpack_from("<2i", data, b + 56)
                        analyze(name, data[off:off + size], stats)
                elif low.endswith(".bsp") and os.path.basename(dp).lower() == "maps":
                    if low in seen:
                        continue
                    seen.add(low)
                    analyze(low, open(p, "rb").read(), stats)

    print("maps scanned: %d   nodes: %d   leafs: %d   max leafs in one map: %d"
          % (stats["maps"], stats["nodes"], stats["leafs"], stats["max_leafs"]))
    print("max nodes in one map: %d (%s)   MAX_MAP_NODES = 65536"
          % (stats["max_nodes"], stats["max_nodes_map"][0]))
    print("whole-lump shared node references: %d   whole-lump references of node 0: %d"
          % (stats["wholelump_shared_nodes"], stats["wholelump_root_referenced"]))
    print("whole-lump shared leaf references: non-solid %d   solid %d"
          % (stats["wholelump_shared_nonsolid"], stats["wholelump_shared_solid"]))
    print("whole-lump out-of-range child indexes: %d" % stats["wholelump_oob_children"])
    print("max world-tree depth from node 0: %d   (deepest submodel headnode tree: %d)"
          % (stats["max_depth"], stats["max_depth_models"]))
    print("nodes not reachable from node 0 (submodel trees): %d"
          % stats["nodes_not_in_world_tree"])
    print("leaf references shared by SOLID leaves: %d  (leaf 0 class, legal)"
          % stats["shared_solid_leafrefs"])
    for key in ("skipped_ident", "funny_lump", "oob_node_child", "oob_leaf_child",
                "oob_headnode", "leafs_over_MAX_MAP_LEAFS", "cycle_root",
                "rootwalk_shared_nodes", "rootwalk_shared_nonsolid_leafs",
                "modelroot_shared_nodes"):
        v = stats[key]
        print("%s: %s" % (key, (v if len(v) <= 8 else "%d maps: %s..." % (len(v), v[:8]))
                          if v else 0))


main()
