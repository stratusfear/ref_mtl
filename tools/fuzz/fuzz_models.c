/*
 * Copyright (C) 2026 ref_mtl port
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or (at
 * your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 *
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 * 02110-1301, USA.
 */

/*
 * AE1: libFuzzer target for the alias/sprite model loaders
 * (src/files/models.c).
 *
 * Entry points (both take the model buffer directly, like the
 * renderer's RegisterModel path hands it over):
 *
 *   Mod_LoadAliasModel()  version-dispatching MDL / MD2 loader,
 *                         including the Daikatana .dkm variant
 *   Mod_LoadSP2()         Quake 2 sprite model loader
 *
 * These are the loaders that use the real hunk allocator, so the
 * Hunk_MemoryRemaining() bookkeeping in the guard is live here: a
 * completed load deliberately keeps its hunk (expect_mapped), any
 * other exit must give it all back.
 */

#include "fuzz_common.h"

#include <stdlib.h>
#include <string.h>

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	static struct image_s *skins[MAX_FRAMES + MAX_MD2SKINS + 8];
	vec3_t		mins, maxs;
	modtype_t	type;
	void		*model;

	if (!data || (size == 0))
	{
		return 0;
	}

	MemFS_Clear();
	MemFS_Stage("probe", data, (int)size);

	memset(skins, 0, sizeof(skins));

	FUZZ_GUARD_BEGIN();
	model = Mod_LoadAliasModel("probe.md2", data, (int)size, mins, maxs,
			skins, FuzzFindImage, &type);
	if (model)
	{
		fuzz_load_ok++;
	}
	FUZZ_GUARD_END("Mod_LoadAliasModel", model != NULL);

	memset(skins, 0, sizeof(skins));

	FUZZ_GUARD_BEGIN();
	model = Mod_LoadSP2("probe.sp2", data, (int)size, skins,
			FuzzFindImage, &type);
	if (model)
	{
		fuzz_load_ok++;
	}
	FUZZ_GUARD_END("Mod_LoadSP2", model != NULL);

	MemFS_Clear();
	return 0;
}
