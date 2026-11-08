#!/usr/bin/env python3
"""AH1 evidence: largest image dimensions claimed by the texture files
this machine's game data can feed to the stb decode path.

Mirrors what LoadSTB (src/files/stb.c) can be asked to decode: the
retexturing path (LoadHiColorImage) tries <name>.tga, <name>.png and
<name>.jpg for every texture name, so any of those files in a pak or
loose in a search path is in scope.  Parses only the headers stb
reads its allocation sizes from - TGA footer-less header, PNG IHDR,
JPEG SOFn - not the pixel payloads.

usage:
  python3 scan_img.py <pak0.pak> [pak...] [dir ...]
  (dirs are walked recursively for *.tga/*.png/*.jpg)
"""
import os
import struct
import sys

EXTS = (".tga", ".png", ".jpg", ".jpeg")


def png_dims(d):
    if d[:8] != b"\x89PNG\r\n\x1a\n" or d[12:16] != b"IHDR":
        return None
    w, h = struct.unpack_from(">II", d, 16)
    return w, h


def jpg_dims(d):
    if d[:2] != b"\xff\xd8":
        return None
    i = 2
    n = len(d)
    while i + 9 < n:
        if d[i] != 0xFF:
            i += 1
            continue
        marker = d[i + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        seglen = struct.unpack_from(">H", d, i + 2)[0]
        # SOF0..SOF15 except DHT(C4)/JPGA(C8)/DAC(CC)
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            h, w = struct.unpack_from(">HH", d, i + 5)
            return w, h
        i += 2 + seglen
    return None


def tga_dims(d):
    # TGA has no magic; idlen==0 and a plausible type/depth is the
    # convention every tool uses, and stb's own gate
    if len(d) < 18 or d[0] != 0:
        return None
    ctype = d[2]
    bpp = d[16]
    if ctype not in (1, 2, 3, 9, 10, 11) or bpp not in (8, 15, 16, 24, 32):
        return None
    w, h = struct.unpack_from("<HH", d, 12)
    if w == 0 or h == 0:
        return None
    return w, h


def dims_for(name, d):
    low = name.lower()
    if low.endswith(".png"):
        return png_dims(d)
    if low.endswith((".jpg", ".jpeg")):
        return jpg_dims(d)
    if low.endswith(".tga"):
        return tga_dims(d) or png_dims(d) or jpg_dims(d)
    return None


def pak_blobs(path):
    with open(path, "rb") as f:
        tag, diroff, n, ver = struct.unpack("<4s3i", f.read(16))
        if tag != b"PACK":
            return
        f.seek(diroff)
        for _ in range(n):
            e = f.read(64)
            if len(e) < 64:
                break
            name, off, size = struct.unpack("<56sii", e)
            name = name.split(b"\0")[0].decode("ascii", "replace")
            if not name.lower().endswith(EXTS) or size > 64 << 20:
                continue
            here = f.tell()
            f.seek(off)
            yield name, f.read(size)
            f.seek(here)


def main():
    paks = [a for a in sys.argv[1:] if a.lower().endswith(".pak")]
    dirs = [a for a in sys.argv[1:] if os.path.isdir(a)]
    if not paks and not dirs:
        raise SystemExit(__doc__)
    total = skipped = 0
    best = {".tga": [], ".png": [], ".jpg": [], ".jpeg": []}
    def note(kind, w, h, src):
        best[kind].append((w * h, w, h, src))

    for pak in paks:
        for name, blob in pak_blobs(pak):
            total += 1
            dm = dims_for(name, blob)
            if not dm:
                skipped += 1
                continue
            note(os.path.splitext(name)[1], dm[0], dm[1], "%s!%s" % (pak, name))
    for root_dir in dirs:
        for root, _, files in os.walk(root_dir):
            for fn in files:
                if not fn.lower().endswith(EXTS):
                    continue
                p = os.path.join(root, fn)
                try:
                    with open(p, "rb") as f:
                        blob = f.read(64 << 20)
                except OSError:
                    continue
                total += 1
                dm = dims_for(fn, blob)
                if not dm:
                    skipped += 1
                    continue
                note(os.path.splitext(fn)[1], dm[0], dm[1], p)

    print("scanned %d image files (%d paks, %d dir trees), "
          "%d headers not parseable" % (total, len(paks), len(dirs), skipped))
    for kind in (".tga", ".png", ".jpg", ".jpeg"):
        rows = sorted(best[kind], reverse=True)
        if not rows:
            print("%s: none" % kind)
            continue
        print("%s: %d files" % (kind, len(rows)))
        for px, w, h, src in rows[:5]:
            print("   %8d px  %6dx%-6d %s" % (px, w, h, src[-110:]))
        mx = max(max(r[1], r[2]) for r in rows)
        print("   max side %d, max pixels %d"
              % (mx, max(r[0] for r in rows)))
    allpx = [r[0] for k in best for r in best[k]]
    allside = [max(r[1], r[2]) for k in best for r in best[k]]
    if allpx:
        print("OVERALL: max side %d, max pixel count %d"
              % (max(allside), max(allpx)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
