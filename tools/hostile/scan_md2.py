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

"""Shipped-.md2 header audit (AF2 evidence, AG3 update).

Runs a Python mirror of ref_mtl's Mod_CheckAliasHeader (src/files/
models.c) over every .md2 found in the given .pak archives AND in the
given loose directories (the datadir on this machine keeps maps and
models outside paks too; the round-23 AF2 message counted only pak
entries and got the denominator wrong) and reports which files the
checker rejects, with the rejecting line.  The mirror carries the
AF2.5 section-overlap block: sections must be pairwise disjoint and
must not start inside the generated dmdl_t header.

AG3: the mirror also scores every file under the AG3 variant of the
rule - a zero-size section (count == 0, so end == start: the loader
copies nothing at that offset) skipped by the "inside its own header"
start rule and the overlap test - and prints the verdict CHANGES,
i.e. shipped files the current rule rejects but that carry zero
writes at the offending offset, plus the zero-count census.

usage:
  python3 scan_md2.py <pak0.pak> [pak1.pak ...] [dir ...]
example:
  python3 tools/hostile/scan_md2.py \
      "/Applications/Quake 2.app/Contents/Resources/baseq2"/pak*.pak \
      "/Applications/Quake 2.app/Contents/Resources/xatrix"/pak*.pak \
      "/Applications/Quake 2.app/Contents/Resources/rogue"/pak*.pak \
      rocket-arena-2-data/arena/pak*.pak
"""

import os
import struct
import sys

MAX_SKINNAME = 64
MAX_MD2SKINS = 32
MAX_LBM_HEIGHT = 4096
MAX_VERTS = 8192
MAX_TRIANGLES = 8192
MAX_FRAMES = 512
DMDLT = 68	# sizeof(dmdl_t): 17 ints
DSTVERT = 4	# dstvert_t: 2 shorts
DTRIANGLE = 12	# dtriangle_t: 6 shorts
DALIASFRAME = 44	# daliasframe_t: name[16] + 2 vec3_t + verts[1]
DTRIVERTX = 4	# dtrivertx_t


def check_alias_header(d, skip_empty=False):
    """Mirror of Mod_CheckAliasHeader; None = accept, else the
    Com_Printf text the C code would emit.  skip_empty implements the
    AG3 variant: a section with zero records (end == start) neither
    takes part in the "inside its own header" start rule nor in the
    overlap test, because the loaders copy nothing to its offset."""
    (sw, sh, fs, ns, nxyz, nst, ntri, ngl, nf,
     os_, ost, otri, ofr, ogc, oe) = struct.unpack_from('<15i', d, 8)

    def why(line):
        return line

    if oe < DMDLT:
        return why('ends at %d, before its own header' % oe)
    if sh > MAX_LBM_HEIGHT:
        return why('skin taller than %d' % MAX_LBM_HEIGHT)
    if ns < 0:
        return why('%d skins' % ns)
    if nxyz <= 0:
        return why('no vertices')
    if nxyz > MAX_VERTS:
        return why('too many vertices')
    if fs < DALIASFRAME + (nxyz - 1) * DTRIVERTX:
        return why('framesize %d for %d vertices' % (fs, nxyz))
    if nst <= 0:
        return why('no st vertices')
    if ntri <= 0:
        return why('no triangles')
    if nf <= 0:
        return why('no frames')
    if ngl < 1:
        return why('%d glcmds' % ngl)
    # the MD2 loader clamps num_skins to the model's skin limit before
    # running this checker, so the skin section extent checked (and the
    # extent actually copied) is the clamped one
    ns_chk = ns if ns < MAX_MD2SKINS else MAX_MD2SKINS
    if os_ < 0 or os_ + ns_chk * MAX_SKINNAME > oe:
        return why('%d skins at %d, model ends at %d' % (ns_chk, os_, oe))
    if ost < 0 or ost + nst * DSTVERT > oe:
        return why('%d st vertices at %d, model ends at %d' % (nst, ost, oe))
    if otri < 0 or otri + ntri * DTRIANGLE > oe:
        return why('%d triangles at %d, model ends at %d' % (ntri, otri, oe))
    if ofr < 0 or ofr + nf * fs > oe:
        return why('%d frames of %d bytes at %d, model ends at %d'
                   % (nf, fs, ofr, oe))
    if ogc < 0 or ogc + ngl * 4 > oe:
        return why('%d glcmds at %d, model ends at %d' % (ngl, ogc, oe))
    # AF2.5 pairwise disjointness block
    sect = [
        ('skins', os_, os_ + ns_chk * MAX_SKINNAME),
        ('st', ost, ost + nst * DSTVERT),
        ('triangles', otri, otri + ntri * DTRIANGLE),
        ('frames', ofr, ofr + nf * fs),
        ('glcmds', ogc, ogc + ngl * 4),
    ]
    for name, start, end in sect:
        if skip_empty and end == start:
            continue	# AG3: a zero-record section writes nothing there
        if start < DMDLT:
            return why('its %s section at %d, inside its own header'
                       % (name, start))
    for i in range(len(sect)):
        for j in range(i + 1, len(sect)):
            if skip_empty and (sect[i][1] == sect[i][2] or
                               sect[j][1] == sect[j][2]):
                continue
            if sect[i][1] < sect[j][2] and sect[j][1] < sect[i][2]:
                return why('overlapping %s and %s sections'
                           % (sect[i][0], sect[j][0]))
    return None


def pak_files(path):
    """Yield (name, offset, size) for every entry in one pak.
    Quake II paks are the "PACK v8" form: 4s tag, directory byte
    offset, directory byte length, version; the directory is a run
    of 64-byte entries: name[56], filepos, filelen."""
    with open(path, 'rb') as f:
        tag, doff, dlen, ver = struct.unpack('<4s3i', f.read(16))
        if tag != b'PACK':
            raise SystemExit('%s: not a pak' % path)
        f.seek(doff)
        for _ in range(dlen // 64):
            e = f.read(64)
            if len(e) < 64:
                break
            name, off, size = struct.unpack('<56sii', e)
            yield name.split(b'\0')[0].decode('ascii', 'replace'), off, size


def main():
    paks = [a for a in sys.argv[1:] if a.lower().endswith('.pak')]
    dirs = [a for a in sys.argv[1:] if os.path.isdir(a)]
    if not paks and not dirs:
        raise SystemExit(__doc__)
    files = []			# (display-name, bytes)
    for pak in paks:
        for name, off, size in pak_files(pak):
            if not name.lower().endswith('.md2'):
                continue
            with open(pak, 'rb') as f:
                f.seek(off)
                files.append(('%s!%s' % (pak, name), f.read(size)))
    for d in dirs:
        for root, _, names in os.walk(d):
            for nm in sorted(names):
                if not nm.lower().endswith('.md2'):
                    continue
                p = os.path.join(root, nm)
                with open(p, 'rb') as f:
                    files.append((p, f.read()))
    total = bad = 0
    zero_skins = zero_at0 = changed = 0
    for disp, d in files:
        total += 1
        if len(d) < 148 or d[:4] != b'IDP2':
            continue	# not an alias header; MD2 loader prints ident
        ns = struct.unpack_from('<i', d, 20)[0]
        os_ = struct.unpack_from('<i', d, 44)[0]
        if ns == 0:
            zero_skins += 1
            if os_ < DMDLT:
                zero_at0 += 1
        why = check_alias_header(d)
        why2 = check_alias_header(d, skip_empty=True)
        if why != why2:
            changed += 1
            print('AG3 VERDICT CHANGES %s: now=%s was=%s'
                  % (disp, why2 or 'accept', why or 'accept'))
        if why:
            bad += 1
            print('REJECT %s: %s' % (disp, why))
    print('scanned %d .md2 (%d paks, %d dir trees), rejected %d'
          % (total, len(paks), len(dirs), bad))
    print('zero-skin files: %d, of which ofs_skins < sizeof(dmdl_t): %d; '
          'AG3 rule changes the verdict on %d file(s)'
          % (zero_skins, zero_at0, changed))
    return 0 if bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
