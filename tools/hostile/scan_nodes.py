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

# AG1 evidence: evaluate the proposed Mod_LoadNodes surface-range check
# against every shipped BSP.
#
# The check mirrors the loader: the NODES lump must be a whole number of
# 28-byte dnode_t records, the FACES lump a whole number of 20-byte
# dface_t records, and for every node
#
#     (64-bit) firstface + numfaces <= face records of the same lump pair
#
# A lump that starts outside the file, or whose Z5a clamp truncates it,
# is evaluated on the clamped length, exactly like the loader.
#
# Usage: scan_nodes.py <datadir> [more datadirs...]
# Scans pak files and loose baseq2/maps/*.bsp under each datadir.

import os
import struct
import sys

Q2_ident = 0x50534249  # little-endian "IBSP", files.h:335
BSPVERSION = 38        # files.h:337 (yes, Quake 2 BSP2 carries 38 here)
HEADER_LUMPS = 19
LUMP_NODES = 4
LUMP_FACES = 6
DSIZE = 28   # sizeof(dnode_t)
DFSIZE = 20  # sizeof(dface_t)


def scan_map(name, data, stats, findings):
    if len(data) < 8 + HEADER_LUMPS * 8:
        findings.append((name, "header", 0, 0, 0, 0))
        return
    ident, version = struct.unpack_from("<2i", data, 0)
    if ident != Q2_ident or version != BSPVERSION:
        stats["skipped"].append(name)
        return
    filesize = len(data)
    noff, nlen = struct.unpack_from("<2i", data, 8 + LUMP_NODES * 8)
    foff, flen = struct.unpack_from("<2i", data, 8 + LUMP_FACES * 8)
    # Z5a: loader rejects these outright; count as "already rejected"
    if (noff < 0 or nlen < 0 or foff < 0 or flen < 0 or
            (nlen > 0 and noff < 160) or (flen > 0 and foff < 160) or
            noff > filesize or foff > filesize):
        findings.append((name, "lumptable", noff, nlen, foff, flen))
        return
    if noff + nlen > filesize:
        nlen = filesize - noff
    if foff + flen > filesize:
        flen = filesize - foff
    if nlen % DSIZE or flen % DFSIZE:
        # funny lump size: already rejected upstream of the new check
        stats["funny_size"].append(name)
        return
    numfaces = flen // DFSIZE
    checked = 0
    for i in range(nlen // DSIZE):
        firstface, numf = struct.unpack_from("<HH", data, noff + i * DSIZE + 24)
        checked += 1
        if firstface + numf > numfaces:
            findings.append((name, "node", i, firstface, numf, numfaces))
    stats["nodes"] += checked


def pak_files(path):
    """Yield (name, offset, size) for every entry in one pak: PACK v8,
    directory of 64-byte entries name[56], filepos, filelen
    (same reader as scan_md2.py)."""
    with open(path, 'rb') as f:
        tag, doff, dlen, ver = struct.unpack('<4s3i', f.read(16))
        if tag != b'PACK':
            return
        f.seek(doff)
        for _ in range(dlen // 64):
            e = f.read(64)
            if len(e) < 64:
                break
            name, off, size = struct.unpack('<56sii', e)
            yield name.split(b'\0')[0].decode('ascii', 'replace'), off, size


def main(argv):
    stats = {"maps": 0, "nodes": 0, "skipped": [], "funny_size": []}
    findings = []
    seen = set()
    for root in argv:
        for dirpath, dirnames, filenames in os.walk(root):
            for fn in sorted(filenames):
                path = os.path.join(dirpath, fn)
                if fn.lower().endswith(".pak"):
                    for name, off, size in pak_files(path):
                        if not name.lower().endswith(".bsp"):
                            continue
                        key = name.lower()
                        if key in seen:
                            continue
                        seen.add(key)
                        stats["maps"] += 1
                        with open(path, 'rb') as f:
                            f.seek(off)
                            scan_map(key, f.read(size), stats, findings)
                elif fn.lower().endswith(".bsp") and \
                        os.path.basename(dirpath).lower() == "maps":
                    key = fn.lower()
                    if key in seen:
                        continue
                    seen.add(key)
                    stats["maps"] += 1
                    scan_map(key, open(path, "rb").read(), stats, findings)
    print("maps scanned: %d" % stats["maps"])
    print("nodes checked: %d" % stats["nodes"])
    print("funny lump size (already rejected upstream): %d" %
          len(stats["funny_size"]))
    for n in stats["funny_size"]:
        print("  funny-size: %s" % n)
    print("skipped (not Q2 BSP2): %d" % len(stats["skipped"]))
    for n in stats["skipped"]:
        print("  skipped: %s" % n)
    print("rejections of the AG1 check: %d" % len(findings))
    for f in findings:
        print("  %s: %s rec %d firstface %d numfaces %d faces %d" % f)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
