/*
 * AE1: libFuzzer target for the WAL / Heretic2 M8 / M32 loaders
 * (src/files/wal.c).
 *
 * Entry points, each fed the fuzzer bytes as the file behind its
 * own fixed name:
 *
 *   LoadWal()/LoadM8()/LoadM32()  full miptex decode through the
 *                                 load_image callback stub
 *   GetWalInfo()/GetM8Info()/
 *   GetM32Info()                  header-only size probes
 */

#include "fuzz_common.h"

#include <stdlib.h>

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	if (!data || (size == 0))
	{
		return 0;
	}

	MemFS_Clear();
	MemFS_Stage("probe.wal", data, (int)size);
	MemFS_Stage("probe.m8", data, (int)size);
	MemFS_Stage("probe.m32", data, (int)size);

	FUZZ_GUARD_BEGIN();
	LoadWal("probe", it_wall, FuzzLoadImage);
	FUZZ_GUARD_END("LoadWal", 0);

	FUZZ_GUARD_BEGIN();
	LoadM8("probe", it_wall, FuzzLoadImage);
	FUZZ_GUARD_END("LoadM8", 0);

	FUZZ_GUARD_BEGIN();
	LoadM32("probe", it_wall, FuzzLoadImage);
	FUZZ_GUARD_END("LoadM32", 0);

	FUZZ_GUARD_BEGIN();
	{
		int w = 0, h = 0;

		GetWalInfo("probe", &w, &h);
		GetM8Info("probe", &w, &h);
		GetM32Info("probe", &w, &h);
	}
	FUZZ_GUARD_END("Get*Info", 0);

	MemFS_Clear();
	return 0;
}
