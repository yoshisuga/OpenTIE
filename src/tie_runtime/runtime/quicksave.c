#include "tie_runtime/runtime/quicksave.h"

#include "tie/math2.h"
#include "tie/msg.h"
#include "tie/replayio.h"
#include "tie/tie.h"
#include "tie_runtime/storage/storage.h"
#include "tie_runtime/timing/flight_checkpoint.h"

#include <string.h>

#include <stdio.h>

/* quickN.rpy is slot N's snapshot; quickN.inf names its mission and carries
 * what the snapshot leaves out. The snapshot's size stands in for its
 * format. */
static void TieQuickSave_Names(int slot, char snapshot[16], char info[16]) {
	snprintf(snapshot, 16, "quick%d.rpy", slot);
	snprintf(info, 16, "quick%d.inf", slot);
}

static bool TieQuickSave_ValidSlot(int slot) { return slot >= 1 && slot <= TIE_QUICKSAVE_SLOTS; }

enum {
	QUICKSAVE_VERSION = 1,
	QUICKSAVE_MISSION_SIZE = 64,
	QUICKSAVE_INFO_SIZE = 4 + 2 + 4 + QUICKSAVE_MISSION_SIZE + 2,
};

/* Pending slots, or 0. */
static int s_save_slot;
static int s_load_slot;
static TieQuickSaveResult s_result;
static int s_result_slot;
static uint32_t s_serial;

void TieQuickSave_RequestSave(int slot) {
	if (TieQuickSave_ValidSlot(slot))
		s_save_slot = slot;
}

void TieQuickSave_RequestLoad(int slot) {
	if (TieQuickSave_ValidSlot(slot))
		s_load_slot = slot;
}

TieQuickSaveResult TieQuickSave_LastResult(uint32_t* serial, int* slot) {
	if (serial)
		*serial = s_serial;
	if (slot)
		*slot = s_result_slot;
	return s_result;
}

static void TieQuickSave_Report(TieQuickSaveResult result, int slot) {
	s_result = result;
	s_result_slot = slot;
	++s_serial;
}

static uint32_t TieQuickSave_Format(void) {
	return (uint32_t)TieFlightCheckpoint_Size() ^ ((uint32_t)sizeof(objects) << 8);
}

static void TieQuickSave_EncodeInfo(uint8_t* out) {
	const uint32_t format = TieQuickSave_Format();
	memset(out, 0, QUICKSAVE_INFO_SIZE);
	memcpy(out, "TQSV", 4);
	out[4] = (uint8_t)QUICKSAVE_VERSION;
	out[5] = (uint8_t)(QUICKSAVE_VERSION >> 8);
	for (int i = 0; i < 4; ++i)
		out[6 + i] = (uint8_t)(format >> (8 * i));
	strncpy((char*)out + 10, missionfilename, QUICKSAVE_MISSION_SIZE - 1);
	out[10 + QUICKSAVE_MISSION_SIZE] = (uint8_t)math2_randomseed;
	out[11 + QUICKSAVE_MISSION_SIZE] = (uint8_t)((uint16_t)math2_randomseed >> 8);
}

/* The seed the checkpoint carries, when it is for this mission and build. */
static bool TieQuickSave_ReadInfo(int slot, int16_t* seed) {
	char snapshot_name[16], info_name[16];
	TieQuickSave_Names(slot, snapshot_name, info_name);
	uint8_t info[QUICKSAVE_INFO_SIZE];
	uint8_t expected[QUICKSAVE_INFO_SIZE];
	TieFile* file = TieStorage_Open(TIE_FILE_ROOT_TEMP, info_name, "rb");
	if (!file)
		return false;
	const size_t read = TieStorage_Read(info, 1, sizeof info, file);
	TieStorage_Close(file);
	TieQuickSave_EncodeInfo(expected);
	/* Everything before the seed must match: magic, version, format, mission. */
	if (read != sizeof info || memcmp(info, expected, QUICKSAVE_INFO_SIZE - 2) != 0)
		return false;
	if (seed)
		*seed = (int16_t)(info[10 + QUICKSAVE_MISSION_SIZE] | info[11 + QUICKSAVE_MISSION_SIZE] << 8);
	return true;
}

bool TieQuickSave_HasCheckpoint(int slot) {
	return TieQuickSave_ValidSlot(slot) && maingameflag && TieQuickSave_ReadInfo(slot, NULL);
}

/* The same conditions as the flight recorder's 'c' key. */
static bool TieQuickSave_Allowed(void) {
	return maingameflag && !replayviewmode && !hyperspaceflag && !pstate.hyperin_state && pstate.player_craft;
}

static TieQuickSaveResult TieQuickSave_Save(int slot) {
	if (!TieQuickSave_Allowed())
		return TIE_QUICKSAVE_UNAVAILABLE;
	char snapshot_name[16], info_name[16];
	TieQuickSave_Names(slot, snapshot_name, info_name);
	uint8_t info[QUICKSAVE_INFO_SIZE];
	TieQuickSave_EncodeInfo(info);
	/* The snapshot first: a failed write leaves no info naming it. */
	TieStorage_Remove(TIE_FILE_ROOT_TEMP, info_name);
	if (!replayio_copytosave(snapshot_name) ||
		!TieStorage_WriteAllAtomic(TIE_FILE_ROOT_TEMP, info_name, info, sizeof info))
		return TIE_QUICKSAVE_FAILED;
	return TIE_QUICKSAVE_SAVED;
}

static TieQuickSaveResult TieQuickSave_Load(int slot) {
	if (!TieQuickSave_Allowed())
		return TIE_QUICKSAVE_UNAVAILABLE;
	char snapshot_name[16], info_name[16];
	TieQuickSave_Names(slot, snapshot_name, info_name);
	int16_t seed;
	if (!TieQuickSave_ReadInfo(slot, &seed))
		return TIE_QUICKSAVE_NO_CHECKPOINT;
	/* A recording would no longer match the flight it records. */
	if (recordingreplay) {
		if (!replayio_spoolreplayinput())
			replaytotalcnt -= replaybuffercnt;
		replaybuffercnt = 0;
		recordingreplay = 0;
	}
	/* As the original returned from the replay viewer to the live flight. */
	if (!replayio_copyfromsave(snapshot_name))
		return TIE_QUICKSAVE_FAILED;
	replayio_setreturnview();
	math2_randomseed = seed;
	return TIE_QUICKSAVE_LOADED;
}

bool TieQuickSave_Service(void) {
	bool loaded = false;
	if (s_save_slot) {
		const int slot = s_save_slot;
		s_save_slot = 0;
		TieQuickSave_Report(TieQuickSave_Save(slot), slot);
	}
	if (s_load_slot) {
		const int slot = s_load_slot;
		s_load_slot = 0;
		const TieQuickSaveResult result = TieQuickSave_Load(slot);
		loaded = result == TIE_QUICKSAVE_LOADED;
		TieQuickSave_Report(result, slot);
	}
	return loaded;
}
