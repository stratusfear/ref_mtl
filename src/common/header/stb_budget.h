/*
 * AJ1 (round 27): the stb image budget bridge.
 *
 * The budget itself lives in the plain-C stb TU (src/files/stb.c):
 * the counter of canvas bytes currently charged, the admit check,
 * the refusal lines.  The Metal TU owns the image slots, the
 * r_stb_budget cvar and the device memory query.  mtl.h is the
 * Metal TU's header and cannot be included by a plain C file, so
 * this header carries only plain-C-compatible prototypes, the two
 * ways the sides cross the boundary.
 *
 * Invariants:
 *   - a successful LoadSTB leaves exactly width*height*4 bytes
 *     charged on its caller's behalf; the caller must either
 *     commit the charge (MTL_STBMarkImage, when the load callback
 *     returned an image) or release it (MTL_STBReleaseBytes);
 *   - a committed charge is released by the Metal TU exactly once,
 *     at whichever site wipes the image slot (MTL_FreeUnusedImages
 *     eviction, MTL_ShutdownImages).
 */
#ifndef STB_BUDGET_H
#define STB_BUDGET_H

struct image_s;

/* floor: below this even an explicit cvar value is not honored;
   the smallest admit the accounting can justify (one 4096x4096
   canvas, the per-file cap's worst case). */
#define STB_BUDGET_FLOOR_BYTES    (64LL * 1024 * 1024)
/* hard ceiling term, before the device query shrinks it; not
   reachable past it from the cvar (svc_stufftext is unfiltered,
   see the clamp comment in mtl_main.m).  The MB form is what the
   clamp compares the float cvar against before casting: a 1e30
   float cast to long long is undefined behaviour. */
#define STB_BUDGET_HARD_MAX_BYTES (4096LL * 1024 * 1024)
#define STB_BUDGET_HARD_MAX_MB    4096.0f

/* implemented in stb.c (called by the Metal TU): */
void MTL_STBReleaseBytes(long long bytes);
void MTL_STBLevelBoundary(void);
long long MTL_STBChargedBytes(void);

/* implemented in mtl_main.m (called by stb.c): the effective
   budget, clamp(cvar, floor, min(4096 MB, 25% of the device's
   recommendedMaxWorkingSetSize)).  Prints one line whenever the
   effective value changes. */
long long MTL_STBEffectiveBudgetBytes(void);

/* implemented in mtl_image.m (called by stb.c): bind the claim to
   the slot the load callback just returned.  Releases the claim
   instead of binding it when the slot cannot carry it: a name
   reuse of an already-charged slot, or an image left sampling
   r_notexture after an upload failure. */
void MTL_STBMarkImage(struct image_s *slot, long long canvas_bytes);

#endif /* STB_BUDGET_H */
