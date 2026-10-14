#ifndef TIE_RUNTIME_RUNTIME_QUICKSAVE_H
#define TIE_RUNTIME_RUNTIME_QUICKSAVE_H

/* In-flight checkpoints: three slots, each for the mission it was saved in.
 * A checkpoint is the flight recorder's own snapshot (replayio_copytosave, as
 * the original took before the replay viewer) plus the random-number state
 * and the mission it belongs to. Requests are taken between frames by the
 * flight task, where the original saved and restored around the viewer. */

#include <stdbool.h>
#include <stdint.h>

typedef enum TieQuickSaveResult {
	TIE_QUICKSAVE_NONE = 0,
	TIE_QUICKSAVE_SAVED,
	TIE_QUICKSAVE_LOADED,
	TIE_QUICKSAVE_NO_CHECKPOINT, /* none for this mission, or an older format */
	TIE_QUICKSAVE_UNAVAILABLE,   /* hyperspace, the replay viewer, or not in a mission */
	TIE_QUICKSAVE_FAILED,
} TieQuickSaveResult;

enum { TIE_QUICKSAVE_SLOTS = 3 };

/* Slots are numbered 1..TIE_QUICKSAVE_SLOTS. */
void TieQuickSave_RequestSave(int slot);
void TieQuickSave_RequestLoad(int slot);

/* Whether the slot holds a checkpoint for the mission being flown. */
bool TieQuickSave_HasCheckpoint(int slot);

/* The flight task's step, between frames. True when a checkpoint was
 * loaded, so the flight clock must be rebased. */
bool TieQuickSave_Service(void);

/* The latest outcome and its slot; serial changes with each one. */
TieQuickSaveResult TieQuickSave_LastResult(uint32_t* serial, int* slot);

#endif
