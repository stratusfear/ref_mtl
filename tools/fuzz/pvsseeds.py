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

"""AE10: seed corpus for fuzz_pvs (the PVS decompressor target).

Seeds are [4-byte little-endian numclusters][bit stream].  The
harness materializes the cluster table virtually; only the stream
bytes reach Mod_DecompressVis.  These are well-formed streams plus
the two shapes the AE4 host test used through a crafted BSP.
"""

import os
import struct
import sys


def literals(n, b, count=64):
    return struct.pack("<i", n) + bytes([b] * count)


def runs(n):
    # 0x03 = three-byte run: copy 2 literal bytes
    return struct.pack("<i", n) + b"\x03ab" * 32


def zerothen(n):
    # zero run then literals then terminating 00 00
    return struct.pack("<i", n) + b"\x00\x08" + b"\x2a" * 8 + b"\x00\x00"


def runaway(n):
    # only 00 00 pairs: writes nothing, old loop walks the stream
    # (and everything after it) forever
    return struct.pack("<i", n) + b"\x00\x00" * 64


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "corpus/fuzz_pvs"
    os.makedirs(out, exist_ok=True)
    seeds = {
        "lit.bin": literals(16, 0x2A),
        "runs.bin": runs(64),
        "zerorun.bin": zerothen(8),
        "runaway_small.bin": runaway(20000),   # under MAX_MAP_LEAFS
        "runaway_big.bin": runaway(100000),    # row past decompressed[]
        "bigrow.bin": literals(100000, 0x2A, 13000),  # row 12500 > 8192
        # AE11: row == buffer size, 8191 literals then a 00 ff header
        # that used to write 255 zeros past the row end
        "overshoot.bin": literals(65536, 0x2A, 8191) + b"\x00\xff",
    }
    for name, blob in seeds.items():
        with open(os.path.join(out, name), "wb") as f:
            f.write(blob)
    print("wrote %d fuzz_pvs seeds to %s" % (len(seeds), out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
