#!/usr/bin/env python3
"""Hostile-input regression runner (round-18 Z9 tooling).

Rebuilds the external audit's hostile inputs with mkbsp.py / mkimg.py
into a scratch game dir, launches the host with the ref_mtl under
test for each case, and asserts:

  survive - the process is still alive at the end of the wait window
            (ERR_DROP drops to the console; it must not kill the host)
  clean   - no "AddressSanitizer" and no segmentation in the logs
  marker  - the expected rejection line appears (substring), or for
            control cases that it does not appear

This is NOT part of tools/fix_verify.sh's gate and runs no shipped
map; it needs a built quake2 host, its data dir (-datadir, the dir
that holds baseq2/pak0.pak) and python3.  Each case is one fresh
process; nothing outside --cfgdir is touched.

usage:
  python3 run_hostile.py --host <path to quake2 binary> \
      --datadir <game data dir> [--cfgdir <scratch home>] \
      [--only <substring>] [--wait <seconds per case>] [--keep]
examples:
  python3 tools/hostile/run_hostile.py --host ../yquake2/out/quake2 \
      --datadir "/path/to/Quake 2.app/Contents/Resources"
  ... --only b_warp1000          # single case
  ... --cfgdir /tmp/q2hostile --keep   # reuse and keep the scratch dir
"""
import argparse, glob, os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))

MD2 = "models/weapons/v_blast/tris.md2"
SP2 = "sprites/s_bfg2.sp2"

# (case, extra argv, expected substring or None, must_not_appear)
# expected None = control: process must survive, and must_not_appear
# (if set) must be absent.  A rejection case passes when the substring
# shows up in the console log or stdout AND the process survives.
CASES = [
    # Z5a: lump table.  A bad OFFSET (negative, inside the header, past
    # EOF) is a hard reject; a past-EOF LENGTH is clamped and the map
    # loads (Z5a policy, mirrors shipped ztnmap1/ztnmap2).
    ("b_lumpneg",        ["+map", "b_lumpneg"],        "is not inside the", None),
    ("b_vertlen",        ["+map", "b_vertlen"],        "references vertex", None),
    ("b_lightlen",       ["+map", "b_lightlen"],       "Map: b_lightlen", None),
    ("b_lightlen_small", ["+map", "b_lightlen_small"], "Map: b_lightlen_small", None),
    # Z5b: face / surfedge / edge index bounds
    ("b_firstedge",      ["+map", "b_firstedge"],      "exceeds the", None),
    ("b_surfedge",       ["+map", "b_surfedge"],       "references edge", None),
    ("b_edgevert",       ["+map", "b_edgevert"],       "references vertex", None),
    # Z5c: visibility tables
    ("b_numclusters",    ["+map", "b_numclusters"],    "cannot hold", None),
    ("b_cluster",        ["+map", "b_cluster"],        "is not in the visibility", None),
    # Z5d: submodel face ranges
    ("b_submodel",       ["+map", "b_submodel"],       "Inline model", None),
    # Z5e: texinfo animation chains
    ("b_texnext",        ["+map", "b_texnext"],        "animates to", None),
    ("b_texcycle",       ["+map", "b_texcycle"],       "does not close", None),
    # Z5f: lightmap extents (plain and DECOUPLED_LM)
    ("b_extents",        ["+map", "b_extents"],        "does not fit the", None),
    ("b_declm_big",      ["+map", "b_declm_big"],      "does not fit the", None),
    # Z5g: face lightofs sample windows (plain and DECOUPLED_LM)
    ("b_lightofs",       ["+map", "b_lightofs"],       "runs past the", None),
    ("b_lightofs_big",   ["+map", "b_lightofs_big"],   "runs past the", None),
    ("b_declm_ofs",      ["+map", "b_declm_ofs"],      "runs past the", None),
    # AG1: node surface range vs the surface array (the af0176 class).
    # The check lives in the renderer loader, so the rejection lands
    # after the spawn banner, at precache; the host must survive it.
    ("b_ag1_wide",         ["+map", "b_ag1_wide"],     "surfaces of the model", None),
    ("b_ag1_edgeover",     ["+map", "b_ag1_edgeover"], "surfaces of the model", None),
    ("b_ag1_edgeeq",       ["+map", "b_ag1_edgeeq"],   "Map: b_ag1_edgeeq",
     "surfaces of the model"),
    # AG2: node-tree shape.  The two shapes the game side walks without
    # complaint reach the renderer's Mod_LoadNodes and are rejected there;
    # the exact-line pair also pins which node/leaf pair the message names.
    ("b_ag2_sharenod",     ["+map", "b_ag2_sharenod"],
     "node 2193 is the child of both node 0 and node 1", None),
    ("b_ag2_shareleaf",    ["+map", "b_ag2_shareleaf"],
     "leaf 5 is the child of both node 1 and node 2", None),
    # AG2 control: the solid leaf may be shared by any number of parents, so
    # the same fixture with a solid leaf must still load.
    ("c_ag2_solidleaf",    ["+map", "c_ag2_solidleaf"], "Map: c_ag2_solidleaf",
     "the node tree is"),
    # AG2: the cycle fixture never reaches this renderer on the host route:
    # the game side walks the same tree first and hangs in its own traversal
    # (measured: the console stops at "------- server initialization ------"
    # and the process is still alive when the window closes).  The
    # assertion here is that the host does not die; the crash itself is
    # measured in the fuzz harness (tools/fuzz/fuzz_nodes.c).
    ("b_ag2_cycleroot",    ["+map", "b_ag2_cycleroot"], None, "Mod_LoadNodes"),
    # AG2: same for a leafs lump past MAX_MAP_LEAFS - the game side rejects
    # the map before the renderer loads it, so the case documents who gets
    # there first; the stack-array bound is the harness' business.
    ("b_ag2_leafbig",      ["+map", "b_ag2_leafbig"],  "Map has too many planes",
     "Mod_LoadNodes"),
    # AH2: nodes lump with zero records.  The game side (CMod_LoadNodes,
    # collision.c:1294) rejects before the renderer is ever asked for the
    # model, so the asserting line here is the game-side one; the
    # renderer's own "has no node records" reject is pinned in the
    # harness instead (p_count_zero), because no +map route reaches it.
    ("b_ag2_zerocount",    ["+map", "b_ag2_zerocount"],
     "with no nodes", None),
    # Z5h: BSPX lightgrid (soft rejection: the map still loads, sans grid)
    ("b_lgrid_neg",      ["+map", "b_lgrid_neg"],      "LIGHTGRID_OCTREE", None),
    ("b_lgrid_hang",     ["+map", "b_lgrid_hang"],     "LIGHTGRID_OCTREE", None),
    # Z7: warp-subdivision bound and the sizing fail-closed family
    ("b_warp1000",       ["+map", "b_warp1000"],       "more than the 60", None),
    ("b_zeroedges",      ["+map", "b_zeroedges"],      "has 0 edges", None),
    # Z8: sky name termination probes (the 63-char name reaches the
    # renderer; the short one exercises its own can't-load line)
    ("b_skysmall",       ["+map", "b_skysmall"],       "can't load zz:", None),
    ("b_sky63",          ["+map", "b_sky63"],          None, "Segmentation"),
    # a header-only file never reaches the renderer: the host's shared
    # CM_LoadMap drops it first (Z5a covers the renderer's own lump
    # guard via b_lumpneg).  Asserted here: the host survives the drop.
    ("b_trunc",          ["+map", "b_trunc"],          "is not CONTENTS_SOLID", None),
    # Z3: hostile textures reached through texinfo names
    ("b_tex_w_wide",     ["+map", "b_tex_w_wide"],     "can't load textures/evil", None),
    ("b_tex_w_zero",     ["+map", "b_tex_w_zero"],     "can't load textures/evil", None),
    ("b_tex_w_badofs",   ["+map", "b_tex_w_badofs"],   "can't load textures/evil", None),
    ("b_tex_w_negofs",   ["+map", "b_tex_w_negofs"],   "can't load textures/evil", None),
    ("b_tex_m_wrap",     ["+map", "b_tex_m_wrap"],     "Couldn't load evil/m_wrap", None),
    # controls: legitimate files must load, silently hostile-looking or not
    ("c_base1",          ["+map", "base1"],            "Map: base1", "Failed to load"),
    ("c_lit1000",        ["+map", "b_lit1000"],        "Map: b_lit1000", "Failed to load"),
    ("c_notex",          ["+map", "b_notex"],          "Couldn't load evil/doesnotexist",
     "Failed to load"),
    ("c_tex_m_ok",       ["+map", "b_tex_m_ok"],       "Map: b_tex_m_ok", "Failed to load"),
    ("c_skin_plain",     ["+map", "base1"],            "Map: base1", "Bad pcx file"),
    # Z3: hostile player skins via the skin cvar.  p_tiny and p_nodata
    # have no console line of their own (silent notexture fallback),
    # the assertion there is survive + clean + the map banner.
    ("s_p_wrap",         ["+set", "skin", "male/p_wrap",   "+map", "base1"], "Bad pcx file", None),
    ("s_p_wrap32",       ["+set", "skin", "male/p_wrap32", "+map", "base1"], "Bad pcx file", None),
    ("s_p_1bpp",         ["+set", "skin", "male/p_1bpp",   "+map", "base1"], "Bad pcx file", None),
    ("s_p_tiny",         ["+set", "skin", "male/p_tiny",   "+map", "base1"], "Map: base1", None),
    ("s_p_nodata",       ["+set", "skin", "male/p_nodata", "+map", "base1"], "Map: base1", None),
    ("s_p_planes",       ["+set", "skin", "male/p_planes", "+map", "base1"], "Bad pcx file", None),
    # AH1: stb canvas-size caps.  Header-only files claiming a huge
    # canvas must be refused BEFORE stbi allocates; the marker pins
    # the exact per-file reason line.  s_t_bomb stages the same-named
    # .tga/.png/.jpg trio, so that run proves all three formats hit
    # the cap (the tga line is asserted; the loader tries the
    # extensions in that order).  The boundary pair (t_sideover: side
    # cap, t_pxover: pixel cap) pins both cap rules; c_t_edge stages
    # exactly-on-cap files with complete payloads, which must DECODE,
    # so no refusal line may appear.  The PNG sibling is caught one
    # layer down instead: stb's own PNG allocation guard
    # ((1<<30)/x/n < y, stb_image.h:5158) fails it before the canvas
    # is sized - asserted as the exact line, because that is the
    # rejection the input really gets, cap or no cap.  AI4: the
    # refusal line states the limits (the same two constants the
    # check uses), so s_t_pxover pins the exact wording; the
    # cap-boundary pair with COMPLETE payloads is new: t_pxexact
    # (8192x2048, exactly 16777216 px) must load like c_t_edge, and
    # t_bigvalid (8192x4096, a shape Z2 would have loaded) must be
    # refused with the limits visible in the line.
    ("s_t_bomb",         ["+set", "skin", "male/t_bomb",   "+map", "base1"],
     "LoadSTB: refusing to decode players/male/t_bomb.tga claiming 27164x26480", None),
    ("s_t_bombpng",      ["+set", "skin", "male/t_bombpng", "+map", "base1"],
     "LoadSTB couldn't load data from players/male/t_bombpng.png: too large!", None),
    ("s_t_bombjpg",      ["+set", "skin", "male/t_bombjpg", "+map", "base1"],
     "LoadSTB: refusing to decode players/male/t_bombjpg.jpg claiming 27164x26480", None),
    ("s_t_sideover",     ["+set", "skin", "male/t_sideover", "+map", "base1"],
     "LoadSTB: refusing to decode players/male/t_sideover.tga claiming 16385x16384", None),
    ("s_t_pxover",       ["+set", "skin", "male/t_pxover",  "+map", "base1"],
     "LoadSTB: refusing to decode players/male/t_pxover.tga claiming "
     "4097x4096 (16781312 pixels; limit 16384 per side, 16777216 pixels)",
     None),
    ("c_t_edge",         ["+set", "skin", "male/c_t_edge",  "+map", "base1"],
     "Map: base1", "refusing to decode"),
    ("s_t_pxexact",      ["+set", "skin", "male/t_pxexact", "+map", "base1"],
     "Map: base1", "refusing to decode"),
    ("s_t_bigvalid",     ["+set", "skin", "male/t_bigvalid", "+map", "base1"],
     "LoadSTB: refusing to decode players/male/t_bigvalid.tga claiming "
     "8192x4096 (33554432 pixels; limit 16384 per side, 16777216 pixels)",
     None),
    # Z6: alias models swapped onto the precached view-model path
    ("m_tris",           ["+map", "base1"], "Failed to load", None),
    ("m_frames",         ["+map", "base1"], "Failed to load", None),
    ("m_skinsneg",       ["+map", "base1"], "Failed to load", None),
    ("m_stneg",          ["+map", "base1"], "Failed to load", None),
    ("m_ofsst",          ["+map", "base1"], "Failed to load", None),
    ("m_glcmds0",        ["+map", "base1"], "Failed to load", None),
    ("f_tiny",           ["+map", "base1"], "Failed to load", None),
    ("d_wrap",           ["+map", "base1"], "Failed to load", None),
    ("s_short",          ["+map", "base1"], "Failed to load", None),
    # AB1: IDPO (Quake 1 .mdl) files on the same view-model path
    ("m_mdl484",          ["+map", "base1"], "is truncated", None),
    ("m_mdlskin0",        ["+map", "base1"], "skin width 0", None),
    ("m_mdlskinneg",      ["+map", "base1"], "skin width -4", None),
    ("m_mdlskinsneg",     ["+map", "base1"], "has -1 skins", None),
    ("m_mdltrisbig",      ["+map", "base1"], "too many triangles", None),
    ("m_mdlframes600",    ["+map", "base1"], "too many frames", None),
    ("m_mdlvindex",       ["+map", "base1"], "vertex index 9", None),
    ("m_mdlextent",       ["+map", "base1"], "is truncated", None),
    # AC1: the rejections that run after Hunk_Begin (the leak exits):
    # MDL group skin / group frame, flex post-header block checks
    ("m_mdlskintype",     ["+map", "base1"], "unsupported skin type 1", None),
    ("m_mdlframetype",    ["+map", "base1"], "unsupported frame type 1", None),
    ("f_badskn",          ["+map", "base1"], "Invalid skin version 7", None),
    ("f_badst",           ["+map", "base1"], "Invalid st coord size", None),
    # AE6: files shorter than the first bytes the loaders read: the
    # ident dispatch (1 byte), MD2 version-before-header-check (5
    # bytes), MDL version/count reads before AB1's bounds (12 bytes).
    # The first two also trip the *host's* precache skin check
    # (cl_download.c) before the renderer sees the file - that is an
    # upstream yquake2 bug of the same family, logged in the AE5
    # report, not ours; allow_download_models 0 skips the host's
    # model read so the staged file reaches the renderer.
    ("m_ae6_ident1",      ["+set", "allow_download_models", "0",
                           "+map", "base1"], "less than its ident", None),
    ("m_ae6_md2short",    ["+set", "allow_download_models", "0",
                           "+map", "base1"], "less than its header", None),
    ("m_ae6_mdlshort",    ["+map", "base1"], "less than its header", None),
    # AF1: DKM glcmd converter (DKMD magic on the same overlay path;
    # no shipped DKMs exist).  The read/write/memset cases all stop
    # at the section bound with the converter's own line; intmin has
    # its count line; frames is the v2 framesize floor, checked
    # before the hunk.  Controls are well-formed v2/v1 DKMs that
    # must load.
    ("m_af1_read",        ["+map", "base1"], "possible broken glcmd", None),
    ("m_af1_write",       ["+map", "base1"], "possible broken glcmd", None),
    ("m_af1_memset",      ["+map", "base1"], "possible broken glcmd", None),
    ("m_af1_intmin",      ["+map", "base1"], "glcmd count -2147483648", None),
    ("m_af1_frames",      ["+map", "base1"], "v2 framesize 168 for 32 vertices", None),
    ("c_af1_dkm_v2",      ["+map", "base1"], None, "Failed to load"),
    ("c_af1_dkm_v1",      ["+map", "base1"], None, "Failed to load"),
    # AF2.5: the fuzz_models finds on the same overlay paths.  The two
    # MD2 files patch ONE offset each of a well-formed v_blast header,
    # so only the new pairwise-disjoint section block rejects them.
    # The flex rows are the second-header, truncated-trailing-header
    # and unterminated-block-name defects; sp2name's frame name runs
    # the full 64 bytes with no NUL (no console line of its own, the
    # assertion is survive + clean; the over-read is caught by the
    # ASan-host leg).  Controls: legal edge coordinates must load.
    ("m_af2_stinhdr",     ["+map", "base1"], "inside its own header", None),
    ("m_af2_ovl",         ["+map", "base1"], "overlapping triangles and glcmds", None),
    ("m_af2_stomp",       ["+map", "base1"], "st section at 1, inside its own header", None),
    # AG3: a section with ZERO records copies nothing at its offset, so
    # its empty range must not be mistaken for a header stomp or an
    # overlap.  Both of these are well-formed v_blast files with
    # num_skins = 0 and one skins-offset patch; they must load.  (The
    # m_af2_* trio above keeps the opposite half: NON-empty sections
    # in the header / overlapping each other still reject.)
    ("c_a3_zeroskins",    ["+map", "base1"], "Map: base1",
     "its skins section at 0, inside its own header"),
    ("c_a3_zeroinside",   ["+map", "base1"], "Map: base1",
     "overlapping skins and frames"),
    ("m_af2_2hdr",        ["+map", "base1"], "has a second header block", None),
    ("m_af2_trun",        ["+map", "base1"], "where a block header needs", None),
    ("m_af2_blk33",       ["+map", "base1"], "Unknown block AAAA", None),
    ("m_af2_texrange",    ["+map", "base1"], "has texcoord 16,0 out of range", None),
    ("m_af2_sp2name",     ["+map", "base1"], None, None),
    ("c_af2_mdledge",     ["+map", "base1"], None, "Failed to load"),
    ("c_af2_sp2name",     ["+map", "base1"], None, "Failed to load"),
    # Z6 controls: well-formed replacements must load
    ("c_md2",            ["+map", "base1"], None, "Failed to load"),
    ("c_flex",           ["+map", "base1"], None, "Failed to load"),
    ("c_sp2",            ["+map", "base1"], None, "Failed to load"),
    ("c_mdl",             ["+map", "base1"], None, "Failed to load"),
]

# staged file copied onto the overlay path for model cases (None = remove
# the overlay so the real pak file loads)
STAGE = {
    "m_tris":     (MD2, "staging/md2_tris.md2"),
    "m_frames":   (MD2, "staging/md2_frames.md2"),
    "m_skinsneg": (MD2, "staging/md2_skins_neg.md2"),
    "m_stneg":    (MD2, "staging/md2_st_neg.md2"),
    "m_ofsst":    (MD2, "staging/md2_ofs_st.md2"),
    "m_glcmds0":  (MD2, "staging/md2_glcmds0.md2"),
    "f_tiny":     (MD2, "staging/fm_tiny.fm"),
    "d_wrap":     (MD2, "staging/dk_wrap.dkm"),
    "s_short":    (SP2, "staging/sp2_short.sp2"),
    "m_mdl484":        (MD2, "staging/mdl_484.md2"),
    "m_mdlskin0":      (MD2, "staging/mdl_skin0.md2"),
    "m_mdlskinneg":    (MD2, "staging/mdl_skinneg.md2"),
    "m_mdlskinsneg":   (MD2, "staging/mdl_skinsneg.md2"),
    "m_mdltrisbig":    (MD2, "staging/mdl_trisbig.md2"),
    "m_mdlframes600":  (MD2, "staging/mdl_frames.md2"),
    "m_mdlvindex":     (MD2, "staging/mdl_vindex.md2"),
    "m_mdlextent":     (MD2, "staging/mdl_extent.md2"),
    "m_mdlskintype":   (MD2, "staging/mdl_skintype.md2"),
    "m_mdlframetype":  (MD2, "staging/mdl_frametype.md2"),
    "f_badskn":        (MD2, "staging/fm_badskn.fm"),
    "f_badst":         (MD2, "staging/fm_badst.fm"),
    "m_ae6_ident1":    (MD2, "staging/ae6_ident1.md2"),
    "m_ae6_md2short":  (MD2, "staging/ae6_md2short.md2"),
    "m_ae6_mdlshort":  (MD2, "staging/ae6_mdlshort.md2"),
    "m_af1_read":      (MD2, "staging/af1_dkm_read.md2"),
    "m_af1_write":     (MD2, "staging/af1_dkm_write.md2"),
    "m_af1_memset":    (MD2, "staging/af1_dkm_memset.md2"),
    "m_af1_intmin":    (MD2, "staging/af1_dkm_intmin.md2"),
    "m_af1_frames":    (MD2, "staging/af1_dkm_frames.md2"),
    "c_af1_dkm_v2":    (MD2, "staging/af1_dkm_okv2.md2"),
    "c_af1_dkm_v1":    (MD2, "staging/af1_dkm_okv1.md2"),
    "m_af2_stinhdr":   (MD2, "staging/af2_md2_stinhdr.md2"),
    "m_af2_ovl":       (MD2, "staging/af2_md2_ovl.md2"),
    "c_a3_zeroskins":  (MD2, "staging/a3_zeroskins.md2"),
    "c_a3_zeroinside": (MD2, "staging/a3_zeroinside.md2"),
    "m_af2_stomp":     (MD2, "staging/af2_md2_stomp.md2"),
    "m_af2_2hdr":      (MD2, "staging/af2_flex_2hdr.fm"),
    "m_af2_trun":      (MD2, "staging/af2_flex_trun.fm"),
    "m_af2_blk33":     (MD2, "staging/af2_flex_blk33.fm"),
    "m_af2_texrange":  (MD2, "staging/af2_mdl_texrange.md2"),
    "m_af2_sp2name":   (SP2, "staging/af2_sp2_name.sp2"),
    "c_af2_mdledge":   (MD2, "staging/c_af2_mdl_edge.md2"),
    "c_af2_sp2name":   (SP2, "staging/c_af2_sp2_name.sp2"),
    "c_md2":      (MD2, "staging/c_md2.md2"),
    "c_flex":     (MD2, "staging/c_flex.fm"),
    "c_sp2":      (SP2, "staging/c_sp2.sp2"),
    "c_mdl":      (MD2, "staging/c_mdl.md2"),
}


def run_case(a, gd, name, extra, wait):
    qlog = os.path.join(gd, "qconsole.log")
    if os.path.exists(qlog):
        os.remove(qlog)
    for cf in glob.glob(os.path.join(gd, "config.cfg")) + glob.glob(os.path.join(gd, "default.cfg")):
        os.remove(cf)
    overlay = os.path.join(gd, MD2)
    overlaysp2 = os.path.join(gd, SP2)
    for p in (overlay, overlaysp2):   # drop any overlay from an earlier case
        if os.path.exists(p):
            os.remove(p)
    if name in STAGE:
        path, src = STAGE[name]
        dst = os.path.join(gd, path)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(os.path.join(gd, "staging", src.split("/", 1)[1]), dst)
    outfile = os.path.join(a.logdir, "hostile.%s.out.txt" % name)
    env = dict(os.environ, HOME=a.home)
    out = open(outfile, "w")
    p = subprocess.Popen(
        [a.host, "-datadir", a.datadir, "-cfgdir", "hgame",
         "+set", "game", "baseq2", "+set", "vid_renderer", "mtl",
         "+set", "vid_fullscreen", "0", "+set", "logfile", "2"] + extra,
        cwd=os.path.dirname(os.path.abspath(a.host)), stdout=out,
        stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
    time.sleep(wait)
    alive = p.poll() is None
    if alive:
        p.terminate()
        # AG2: a case whose hang lives in the GAME side (a cyclic node tree
        # the collision code walks before the renderer ever sees the map)
        # does not answer SIGTERM.  Without the grace-and-kill step the
        # runner itself blocks here forever, so escalate instead.
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
    out.close()
    logs = ""
    if os.path.exists(qlog):
        logs = open(qlog, errors="replace").read()
    logs += open(outfile, errors="replace").read()
    return p.returncode, alive, logs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True, help="quake2 binary to run")
    ap.add_argument("--datadir", required=True, help="game data dir (holds baseq2/pak0.pak)")
    ap.add_argument("--cfgdir", default=None, help="scratch home (default: hostile home under TMPDIR)")
    ap.add_argument("--only", default=None, help="run only cases whose name contains this")
    ap.add_argument("--wait", type=int, default=8, help="seconds per case")
    ap.add_argument("--keep", action="store_true", help="keep the scratch dir afterwards")
    a = ap.parse_args()
    a.host = os.path.abspath(a.host)

    a.home = a.cfgdir or os.path.join(os.environ.get("TMPDIR", "/tmp"), "ref_mtl_hostile")
    a.home = os.path.abspath(a.home)
    a.cfgname = "hgame"
    gd = os.path.join(a.home, a.cfgname, "baseq2")
    a.logdir = os.path.join(a.home, "logs")
    shutil.rmtree(a.home, ignore_errors=True)
    os.makedirs(gd, exist_ok=True)
    os.makedirs(a.logdir, exist_ok=True)
    for gen in ("mkbsp.py", "mkimg.py"):
        subprocess.run([sys.executable, os.path.join(HERE, gen),
                        "--datadir", a.datadir, "--out",
                        os.path.join(a.home, a.cfgname)], check=True)

    fails = 0
    for name, extra, marker, forbidden in CASES:
        if a.only and a.only not in name:
            continue
        rc, alive, logs = run_case(a, gd, name, extra, a.wait)
        crash = ("AddressSanitizer" in logs) or ("Segmentation" in logs)
        if not alive and rc not in (0,):
            why = "died rc=%d (signal %d)" % (rc, -rc) if rc < 0 else "died rc=%d" % rc
        elif crash:
            why = "sanitizer/segmentation in logs"
        elif marker and marker not in logs:
            why = "missing marker %r" % marker
        elif forbidden and forbidden in logs:
            why = "control shows %r" % forbidden
        else:
            why = None
        status = "PASS" if why is None else "FAIL: " + why
        if why:
            fails += 1
        print("%-14s %s" % (name, status), flush=True)

    if not a.keep:
        shutil.rmtree(a.home, ignore_errors=True)
    print("%d case(s), %d failed (logs kept under %s%s)" %
          (len([c for c in CASES if not a.only or a.only in c[0]]), fails,
           a.logdir, "" if a.keep else " minus the removed scratch dir"))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
