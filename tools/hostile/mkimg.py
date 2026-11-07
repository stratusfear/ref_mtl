#!/usr/bin/env python3
"""Hostile image/model generator (round-18 Z9 tooling).

Writes the crafted decoder inputs found by the external audit (rounds
18: Z3, Z6) into <out>/baseq2/... as staging files.  run_hostile.py
copies the per-scenario file onto a precached model path (the game
precaches models/weapons/v_blast/tris.md2 and sprites/s_bfg2.sp2 at
every spawn), so each hostile file loads on `+map base1`.

usage: mkimg.py --datadir <dir with baseq2/pak0.pak> --out <scratch game dir>
requires: python3 (stdlib only); v_blast.md2 is extracted from the paks
"""
import argparse, os, struct


def pak_extract(datadir, want):
    for i in range(9):
        p = os.path.join(datadir, "baseq2", f"pak{i}.pak")
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


def pcx(xmin, ymin, xmax, ymax, bpp=8, planes=1, bpl=1, data=b"", ver=5):
    h = struct.pack("<BBBBHHHHHH48sBBHH58s", 0x0a, ver, 1, bpp, xmin, ymin,
                    xmax, ymax, 72, 72, b"\0" * 48, 0, planes, bpl, 1, b"\0" * 58)
    assert len(h) == 128
    return h + data


def tga(w, h, bpp=32, rle=False, data=None):
    t = 10 if rle else 2
    hdr = struct.pack("<BBBHHBHHHHBB", 0, 0, t, 0, 0, 0, 0, 0, w, h, bpp, 8)
    return hdr + (data if data is not None else b"")


def wal(w, h, ofs, body):
    return struct.pack("<32sII4I32siii", b"evil", w, h, ofs, ofs, ofs, ofs,
                       b"", 0, 0, 0) + body


def m32(w, h, ofs, body):
    hdr = struct.pack("<i128s128s128s128s16I16I16Iiiiffi128sfffffii80s",
                      4, b"evil", b"", b"", b"",
                      *([w] + [0] * 15), *([h] + [0] * 15), *([ofs] + [0] * 15),
                      0, 0, 0, 1.0, 1.0, 0, b"", 0, 0, 0, 0, 0, 0, 0, b"")
    assert len(hdr) == 968, len(hdr)
    return hdr + body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--datadir", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    b = os.path.join(a.out, "baseq2")
    out = {}

    # PCX variants: hostile skins under players/male/ (Z3)
    out["players/male/p_wrap.pcx"] = pcx(0x8000, 0x8000, 0x7fff, 0x7fff,
                                         bpl=0x7fff, data=b"\x00" * 64 + b"\x0c" + b"\0" * 768)
    out["players/male/p_wrap32.pcx"] = pcx(0, 0, 32767, 32768, planes=3,
                                           bpl=32768, data=b"\0" * 64)
    out["players/male/p_1bpp.pcx"] = pcx(0, 0, 199, 1, bpp=1, planes=1, bpl=1,
                                         data=b"\x01" * 8)
    out["players/male/p_tiny.pcx"] = b"\x0a\x05\x01\x08\x00\x00"
    out["players/male/p_nodata.pcx"] = pcx(0, 0, 63, 63, bpl=64)
    out["players/male/p_planes.pcx"] = pcx(0, 0, 63, 63, planes=4, bpl=8,
                                           data=b"\x41" * 4096)

    # TGA variants (kept as staging files; not auto-staged by the runner)
    out["players/male/t_wide.tga"] = tga(16385, 1, data=b"\x80" * 16385 * 4)
    out["players/male/t_zero.tga"] = tga(0, 0)
    out["players/male/t_huge.tga"] = tga(20000, 20000, rle=True,
                                         data=b"\xff\x10\x20\x30\x40" * 64)
    out["players/male/t_trunc.tga"] = tga(64, 64, data=b"\x01" * 10)

    # WAL/M32 variants referenced by the b_tex_* maps from mkbsp.py (Z3)
    out["textures/evil/w_wide.wal"] = wal(20000, 1, 100, b"\x10" * 20000)
    out["textures/evil/w_zero.wal"] = wal(0, 0, 100, b"\x10" * 16)
    out["textures/evil/w_badofs.wal"] = wal(16, 16, 0x7ffffff0, b"\x10" * 256)
    out["textures/evil/w_negofs.wal"] = wal(16, 16, 0xfffffff0, b"\x10" * 256)
    out["textures/evil/m_wrap.m32"] = m32(0x40000001, 1, 968, b"\x7f" * 16)
    out["textures/evil/m_ok.m32"] = m32(4, 4, 968, b"\x7f" * 64)

    # alias-model variants, mutated from the real v_blast view model (Z6)
    VB = pak_extract(a.datadir, "models/weapons/v_blast/tris.md2")
    F = "ident version skinwidth skinheight framesize num_skins num_xyz num_st " \
        "num_tris num_glcmds num_frames ofs_skins ofs_st ofs_tris ofs_frames " \
        "ofs_glcmds ofs_end".split()

    def md2(**kw):
        h = list(struct.unpack("<4s16i", VB[:68]))
        for k, v in kw.items():
            h[F.index(k)] = v
        return struct.pack("<4s16i", *h) + VB[68:]

    out["staging/md2_tris.md2"] = md2(num_tris=400000)
    out["staging/md2_skins_neg.md2"] = md2(num_skins=-1)
    out["staging/md2_frames.md2"] = md2(num_frames=100000)
    out["staging/md2_glcmds0.md2"] = md2(num_glcmds=0)
    out["staging/md2_ofs_st.md2"] = md2(ofs_st=0x7ffffff0)
    out["staging/md2_st_neg.md2"] = md2(num_st=-5)

    # AE6: files shorter than the bytes the loaders read before they
    # check the length: 1 byte (ident dispatch read), 5 bytes (IDP2
    # + 1: MD2 version read before the Z6 header check), 12 bytes
    # (IDPO + 8: MDL version/count reads before AB1's inputextent).
    out["staging/ae6_ident1.md2"] = b" "
    out["staging/ae6_md2short.md2"] = b"IDP2\x00"
    out["staging/ae6_mdlshort.md2"] = b"IDPO" + struct.pack("<2i", 6, 0) + b"\0" * 4
    out["staging/c_md2.md2"] = VB

    # SP2: header claims 32 frames, file is only the 12-byte header (Z6)
    out["staging/sp2_short.sp2"] = struct.pack("<4sii", b"IDS2", 2, 32)
    out["staging/c_sp2.sp2"] = pak_extract(a.datadir, "sprites/s_bfg2.sp2")

    # Flex: 4-byte file ("head" magic only) and a well-formed .fm rebuilt
    # from v_blast (control) (Z6)
    out["staging/fm_tiny.fm"] = b"head"

    def fm_block(name, version, body):
        return name.encode().ljust(32, b"\0") + struct.pack("<2i", version, len(body)) + body

    (_, ver, sw, sh, fs, nskin, nxyz, nst, ntri, ncmd, nfr,
     o_skins, o_st, o_tris, o_frames, o_glcmds, o_end) = struct.unpack_from("<17i", VB, 0)
    fmb = fm_block("header", 2, struct.pack("<10i",
        sw, sh, fs, nskin, nxyz, nst, ntri, ncmd, nfr, 0))
    fmb += fm_block("skin", 1, VB[o_skins:o_skins + nskin * 64])
    fmb += fm_block("st coord", 1, VB[o_st:o_st + nst * 4])
    fmb += fm_block("tris", 1, VB[o_tris:o_tris + ntri * 12])
    fmb += fm_block("frames", 1, VB[o_frames:o_frames + nfr * fs])
    fmb += fm_block("glcmds", 1, VB[o_glcmds:o_glcmds + ncmd * 4])
    out["staging/c_flex.fm"] = fmb

    # MDL (Quake 1 alias, magic IDPO): a file starting with IDPO on the
    # view-model path reaches Mod_LoadMDL (AB1).  mdl() assembles a
    # well-formed file; the variants below break one input each.
    def mdl_hdr(num_skins, sw, sh, xyz, tris, frames):
        h = struct.pack("<4si10f8if", b"IDPO", 6,
                        1.0, 1.0, 1.0,          # scale
                        0.0, 0.0, 0.0,          # translate
                        32.0,                   # boundingradius
                        0.0, 0.0, 0.0,          # eyeposition
                        num_skins, sw, sh,      # skins
                        xyz, tris, frames,      # geometry counts
                        0, 0,                   # synctype, flags
                        1.0)                    # size
        assert len(h) == 84, len(h)
        return h

    def mdl(num_skins=1, sw=16, sh=16, xyz=3, tris=1, frames=1,
            verts=None, pad=0, skin_type=0, frame_type=0, st=None):
        if verts is None:
            verts = [(0, 1, 2)] * tris
        body = b""
        for i in range(max(num_skins, 0)):
            body += struct.pack("<i", skin_type) + bytes(max(sw * sh, 0))
        for i in range(xyz):
            if st and i == 0:
                body += struct.pack("<3i", 0, *st)   # onseam, s, t
            else:
                body += struct.pack("<3i", 2 * i, 2 * i + 1, 0)
        for i in range(max(tris, 0)):
            body += struct.pack("<4i", 1, *verts[i])         # facesfront + 3 vert
        for f in range(max(frames, 0)):
            body += (struct.pack("<i", frame_type) + b"\0" * 4 + b"\0" * 4 +
                     b"frame".ljust(16, b"\0") + b"\0" * (4 * xyz))
        return mdl_hdr(num_skins, sw, sh, xyz, tris, frames) + body + b"\0" * pad

    # the reviewer's file: 84-byte header plus 400 zero bytes, claiming a
    # 480x480 skin (defect: the input walk is never bounded by the length)
    out["staging/mdl_484.md2"] = mdl_hdr(1, 480, 480, 3, 1, 1) + b"\0" * 400
    # zero and negative skin width: the skin advance and the s division
    out["staging/mdl_skin0.md2"] = mdl(1, 0, 16, 3, 1, 1, pad=120)
    out["staging/mdl_skinneg.md2"] = mdl(1, -4, 16, 3, 1, 1, pad=120)
    # negative num_skins (drives ofs_st backwards into the header)
    out["staging/mdl_skinsneg.md2"] = mdl(-1, 16, 16, 3, 1, 1)
    # triangle and frame counts beyond MAX_TRIANGLES/MAX_FRAMES
    out["staging/mdl_trisbig.md2"] = mdl_hdr(0, 16, 16, 3, 400000, 1) + \
        b"\0" * (3 * 12 + 40)
    out["staging/mdl_frames.md2"] = mdl(1, 16, 16, 3, 1, 600, pad=24000)
    # a triangle vertex index beyond num_xyz (old code reads texcoords[9]
    # and stores the index through a short for the renderer to replay)
    out["staging/mdl_vindex.md2"] = mdl(1, 16, 16, 3, 1, 1, verts=[(0, 1, 9)])
    # AC1 leak probe only: the same vertex-index rejection, but with a
    # 480x480 skin so the leaked post-Hunk_Begin mapping is ~230 kB and
    # visible to vmmap region accounting
    out["staging/mdl_leakmd.md2"] = mdl(1, 480, 480, 3, 1, 1,
                                        verts=[(0, 1, 9)])
    # 20 skins of 480x480 claimed but only 1.4 kB of pixels present:
    # ofs_end fits the file (the old check passes) but the skin walk
    # leaves the buffer on the second skin
    out["staging/mdl_extent.md2"] = mdl_hdr(20, 480, 480, 3, 1, 1) + \
        struct.pack("<i", 0) + b"\0" * 1432
    # control: a well-formed 1-skin MDL that must load
    out["staging/c_mdl.md2"] = mdl(1, 16, 16, 3, 1, 1)
    # AC1: the two older post-Hunk_Begin rejections, one input each:
    # a group skin (type != 0) and a group frame (type != 0)
    out["staging/mdl_skintype.md2"] = mdl(1, 16, 16, 3, 1, 1, skin_type=1)
    out["staging/mdl_frametype.md2"] = mdl(1, 16, 16, 3, 1, 1, frame_type=1)

    # AC1: flex post-header block rejections, rebuilt from the same
    # v_blast sections as the control, one block header broken each:
    # the skin block version and the st coord block size
    def fm_with(name, version=None, size_delta=0):
        d = bytearray(fmb)
        i = 0
        while i < len(d):
            blen = struct.unpack_from("<i", d, i + 36)[0]
            if d[i:i + 32].split(b"\0")[0].decode("latin1") == name:
                if version is not None:
                    struct.pack_into("<i", d, i + 32, version)
                if size_delta:
                    struct.pack_into("<i", d, i + 36, blen + size_delta)
                break
            i += 40 + blen
        return bytes(d)

    out["staging/fm_badskn.fm"] = fm_with("skin", version=7)
    out["staging/fm_badst.fm"] = fm_with("st coord", size_delta=4)

    # DKM: valid header geometry with a frame-section product wrapping to 0 (Z6)
    dkm = struct.pack("<2i3f15i", 0x444D4B44, 1, 0.0, 0.0, 0.0,
                      0x20000000,          # framesize
                      0, 4, 0, 0,          # num_skins num_xyz num_st num_tris
                      1,                   # num_glcmds
                      0x20000000,          # num_frames (product wraps to 0)
                      0,                   # num_surf
                      128, 128, 128, 128, 128, 128,
                      132)                 # ofs_end
    out["staging/dk_wrap.dkm"] = dkm + b"\0" * (132 - len(dkm))

    # AF1: hand-built DKM (Daikatana alias, DKMD magic) files, there
    # are no shipped DKMs in any game.  dkm() assembles the 20-dword
    # header and one well-formed copy of each checked section: a skin
    # name, num_st stverts, num_tris dkmtriangles, num_frames frames
    # of fs bytes, num_glcmds glcmd dwords.  glcmds is the section
    # content (command dword, two skipped dwords, then 3 dwords per
    # vertex for |command| vertices; a negative command is a fan);
    # ext_ints pads zero dwords past the glcmds section, still inside
    # the file.  With the Z6 checks in place, everything these cases
    # break is the glcmd walk itself.
    def dkmf(ver=2, num_xyz=3, num_st=3, num_tris=1, num_frames=1,
             num_skins=1, glcmds=(), nglcmds=13, fs=None, ext_ints=0,
             frames_last=False):
        if fs is None:
            fs = 40 + 5 * num_xyz if ver == 2 else 40 + 4 * num_xyz
        SK, ST, TRI = 64 * num_skins, 8 * num_st, 8 * num_tris
        FR = fs * num_frames
        ofs = {"skins": 80}
        ofs["st"] = ofs["skins"] + SK
        ofs["tris"] = ofs["st"] + ST
        if frames_last:
            ofs["glcmds"] = ofs["tris"] + TRI
            ofs["frames"] = ofs["glcmds"] + 4 * nglcmds
        else:
            ofs["frames"] = ofs["tris"] + TRI
            ofs["glcmds"] = ofs["frames"] + FR
        bodylen = SK + ST + TRI + FR + 4 * nglcmds
        ofs_end = ofs["glcmds"] + 4 * nglcmds
        h = struct.pack("<2i3f15i", 0x444D4B44, ver, 0.0, 0.0, 0.0,
                        fs, num_skins, num_xyz, num_st, num_tris,
                        nglcmds, num_frames, 0,
                        ofs["skins"], ofs["st"], ofs["tris"],
                        ofs["frames"], ofs["glcmds"], 0, ofs_end)
        body = bytearray(b"\0" * bodylen)
        body[ofs["skins"] - 80:ofs["skins"] - 80 + 6] = b"skin0\0"
        body[ofs["st"] - 80:ofs["st"] - 80 + ST] = \
            struct.pack("<4h", 0, 0, 8, 8) * num_st
        body[ofs["tris"] - 80:ofs["tris"] - 80 + TRI] = \
            struct.pack("<8h", 0, 1, 0, 1, 2, 0, 1, 2) * num_tris
        frame = (b"frame0\0".ljust(16, b"\0") +
                 struct.pack("<6f", 1, 1, 1, 0, 0, 0))
        frame = (frame + b"\0" * (fs - len(frame))) * num_frames
        body[ofs["frames"] - 80:ofs["frames"] - 80 + FR] = frame
        body[ofs["glcmds"] - 80:ofs["glcmds"] - 80 + 4 * len(glcmds)] = \
            struct.pack("<%di" % len(glcmds), *glcmds)
        return h + bytes(body) + b"\0" * (4 * ext_ints)

    # one triangle strip command (3 verts) plus the terminating zero,
    # 1 + 2 + 9 + 1 = 13 dwords: exactly the promised section
    DCTRL = [3, 0, 0] + [0x0A000000 + i for i in range(9)] + [0]
    out["staging/af1_dkm_okv2.md2"] = dkmf(2, glcmds=DCTRL)
    out["staging/af1_dkm_okv1.md2"] = dkmf(1, glcmds=DCTRL)
    # READ: 1 + 2 + 3*268435455 input dwords chased through a
    # 13-dword section: the walk runs off the end of the file buffer
    out["staging/af1_dkm_read.md2"] = dkmf(2, glcmds=[0x0FFFFFFF])
    # WRITE: count 1000 fits the file (zero padding after the
    # section) but its 3001 output dwords do not fit the model's
    # 13-dword glcmds area: the walk writes past the model block,
    # which is the end of the hunk mapping
    out["staging/af1_dkm_write.md2"] = dkmf(2, glcmds=[1000], ext_ints=2990)
    # memset: same overrun but small (output 40 vs 13 dwords, inside
    # the hunk mapping's page slack), so the broken-glcmd break runs
    # and its (pendcmd - poutcmd) is negative: huge memset size_t
    out["staging/af1_dkm_memset.md2"] = dkmf(2, glcmds=[13], ext_ints=30)
    # INT_MIN: count negation is signed overflow UB before anything
    # else in the walk runs
    out["staging/af1_dkm_intmin.md2"] = dkmf(2, glcmds=[-2147483648])
    # frames (AF1 family audit): v2 frames are 40 + 5*num_xyz bytes
    # of input, the file claims 40 + 4*num_xyz (legal for the model
    # side), and the frames section ends the file: the last frame's
    # vertex reads run num_xyz bytes past the file end
    out["staging/af1_dkm_frames.md2"] = dkmf(2, num_xyz=32, num_st=32,
                                            glcmds=DCTRL, fs=168,
                                            frames_last=True)

    # AF2.5: the defects the long fuzz_models legs found, one minimal
    # repro each.  MD2: the Z6 bounds keep every section inside
    # ofs_end but not out of each other's or the header's way; both
    # files are the well-formed v_blast header with ONE offset field
    # patched, so only the new pairwise-disjoint block in
    # Mod_CheckAliasHeader rejects them.
    d = bytearray(VB)
    struct.pack_into("<i", d, 48, 44)	    # ofs_st into the dmdl_t header
    out["staging/af2_md2_stinhdr.md2"] = bytes(d)
    d = bytearray(VB)
    struct.pack_into("<i", d, 60, o_tris)   # glcmds over triangles
    out["staging/af2_md2_ovl.md2"] = bytes(d)
    # The fuzzer's own MD2 repro, rebuilt here so the fixture is
    # generator-only (tools/fuzz/crashers/ is not committed): the
    # libFuzzer-minimised unit (13496 B) has the dmdl_t below and
    # 13428 bytes of body.  num_skins 513 is clamped to MAX_MD2SKINS
    # before Z6's checks, so nothing bounds the RAW 513; ofs_st = 1
    # makes the st list write into the model's own header, and the
    # header's num_skins is re-stamped with 513 by that write after
    # the loader's own clamp, so the LAST copy - the skins memcpy at
    # models.c:1151 (1048 at the pre-fix baseline),
    # pheader->num_skins * MAX_SKINNAME = 32832 bytes - runs off the
    # end of the 13496-byte file buffer.  Rebuilt from v_blast's body
    # with the crasher's header, this file reproduces that signature
    # exactly (ASan heap-buffer-overflow READ of size 32832, "0 bytes
    # after 13496-byte region") on the pre-fix fuzz build, and the
    # fixed loader rejects it with the reason line the case asserts.
    STOMP_HDR = struct.pack("<4s16i", b"IDP2",
                            8, 260, 195, 448,          # ver sw sh framesize
                            513, 102, 113, 192, 843, 16,  # nskins xyz st tris
                                                       #  ncmd nframes
                            68, 1, 584, 2888, 10056, 13428)  # ofs_*    assert len(STOMP_HDR) == 68, len(STOMP_HDR)
    out["staging/af2_md2_stomp.md2"] = (STOMP_HDR +
                                        VB[68:68 + 13428])[:13496]
    # flex: a second header block (would re-run Hunk_Begin), a
    # truncated trailing block header (loop-top reject after
    # Hunk_Begin), and a block name that fills all 32 bytes with no
    # terminator (the %s print used to run over the stack copy)
    hdrbody = struct.pack("<10i", sw, sh, fs, nskin, nxyz, nst, ntri,
                          ncmd, nfr, 0)
    out["staging/af2_flex_2hdr.fm"] = fmb + fm_block("header", 2, hdrbody)
    out["staging/af2_flex_trun.fm"] = fmb + b"head" + b"\0" * 16
    # NOTE the AAAA block goes LAST: the format's magic is the first
    # four bytes of the first block name ("head" = RAVENFMHEADER), so
    # a file that starts with a 32-byte name never reaches the block
    # loop at all - Mod_LoadAliasModel's ident switch drops it with
    # "unknown fileid" (measured: that is what a leading-AAAA file
    # does on the host).
    out["staging/af2_flex_blk33.fm"] = (fmb + b"A" * 32 +
                                        struct.pack("<2i", 2, 0))
    # MDL: texcoord at skinwidth (the short-narrowing / float-cast
    # overflow input); 16x16 skin, s=16 is one past the format range
    out["staging/af2_mdl_texrange.md2"] = mdl(1, 16, 16, 3, 1, 1,
                                              st=(16, 0))
    # SP2: frame name fills the whole 64-byte field with no NUL; the
    # snprintf("sprites/%s") fallback used to read past the file
    # buffer.  No console line of its own (the sprite simply is not
    # found): the assertion is survive + clean, over-read or not is
    # the ASan host leg's business (af2 rows run under both hosts).
    out["staging/af2_sp2_name.sp2"] = (struct.pack("<4sii", b"IDS2", 2, 1) +
                                       struct.pack("<4i", 4, 4, 0, 0) +
                                       b"af2sp2nametest" * 4 + b"deadbeef")
    # controls for the same loaders with one valid extra each: a flex
    # file whose blocks are all intact must still load (c_flex above),
    # an MDL whose texcoords sit at the LAST legal coordinate, and an
    # SP2 whose name is 63 chars plus NUL
    out["staging/c_af2_mdl_edge.md2"] = mdl(1, 16, 16, 3, 1, 1,
                                            st=(15, 15))
    out["staging/c_af2_sp2_name.sp2"] = (struct.pack("<4sii", b"IDS2", 2, 1) +
                                         struct.pack("<4i", 4, 4, 0, 0) +
                                         b"af2edge".ljust(64, b"\0"))


    for k, v in out.items():
        p = os.path.join(b, k)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "wb").write(v)
    print(len(out), "files")


if __name__ == "__main__":
    main()
