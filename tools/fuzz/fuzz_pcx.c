/*
 * AE1: libFuzzer target for the PCX loader (src/files/pcx.c).
 *
 * Exercises the two engine-reachable entry points with the fuzzer
 * bytes staged as the file behind the name, exactly as the host
 * hands a pak buffer to them:
 *
 *   LoadPCX()    full decode, palette handling, quitscreen fix
 *   GetPCXInfo() header-only size probe
 *
 * pics/colormap.pcx is staged with the same bytes so the colormap
 * side-load inside pcx.c sees data instead of a missing file.
 */

#include "fuzz_common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	byte	*pic = NULL, *palette = NULL;
	int		width = 0, height = 0, bpp = 0;

	if (!data || (size == 0))
	{
		return 0;
	}

	MemFS_Clear();
	MemFS_Stage("probe.pcx", data, (int)size);
	MemFS_Stage("pics/colormap.pcx", data, (int)size);

	/* Entry point 1: the full loader. */
	FUZZ_GUARD_BEGIN();
	LoadPCX("probe", &pic, &palette, &width, &height, &bpp);
	if (pic)
	{
		fuzz_load_ok++;
	}
	FUZZ_GUARD_END("LoadPCX", 0);

	free(pic);
	free(palette);
	pic = NULL;
	palette = NULL;

	/* Entry point 2: header probe. */
	FUZZ_GUARD_BEGIN();
	GetPCXInfo("probe", &width, &height);
	FUZZ_GUARD_END("GetPCXInfo", 0);

	MemFS_Clear();
	return 0;
}
