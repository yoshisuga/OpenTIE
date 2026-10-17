#include "tie_3ds/settings_3ds.h"

#include "aeron/log.h"
#include "tie_app/config/app_config.h"
#include "tie_runtime/input/controller_mapping.h"
#include "tie_runtime/input/input.h"

#include <stdio.h>
#include <string.h>

#define TIE_3DS_SETTINGS_PATH "sdmc:/3ds/OpenTIE/3ds_settings.txt"

/* 3DS-only settings, one "name value" line each. */
static bool s_local_loaded;
static bool s_gyro;

static void TieN3dsSettings_LoadLocal(void) {
	if (s_local_loaded)
		return;
	s_local_loaded = true;
	FILE* file = fopen(TIE_3DS_SETTINGS_PATH, "r");
	if (!file)
		return;
	char name[32];
	int value = 0;
	while (fscanf(file, "%31s %d", name, &value) == 2)
		if (strcmp(name, "gyro") == 0)
			s_gyro = value != 0;
	fclose(file);
}

static void TieN3dsSettings_SaveLocal(void) {
	FILE* file = fopen(TIE_3DS_SETTINGS_PATH, "w");
	if (!file) {
		Aeron_LogWarn("tie.3ds", "could not save %s", TIE_3DS_SETTINGS_PATH);
		return;
	}
	fprintf(file, "gyro %d\n", s_gyro ? 1 : 0);
	fclose(file);
}

/* Stick inversion applies to every gamepad model in the configuration (on
 * the 3DS, its built-in controls). The stored flag is the player-facing
 * preference. */
static int TieN3dsSettings_Axis(TieN3dsSetting setting) {
	switch (setting) {
		case TIE_3DS_SETTING_INVERT_PITCH:
			return TIE_INPUT_AXIS_PITCH;
		case TIE_3DS_SETTING_INVERT_YAW:
			return TIE_INPUT_AXIS_YAW;
		case TIE_3DS_SETTING_INVERT_ROLL:
			return TIE_INPUT_AXIS_ROLL;
		default:
			return -1;
	}
}

bool TieN3dsSettings_Get(TieN3dsSetting setting) {
	if (setting == TIE_3DS_SETTING_GYRO) {
		TieN3dsSettings_LoadLocal();
		return s_gyro;
	}
	const TieAppConfigState* config = TieAppConfig_Current();
	const int axis = TieN3dsSettings_Axis(setting);
	if (!config || axis < 0)
		return false;
	const TieControllerOptions* controllers = &config->requested.controller;
	for (size_t i = 0; i < controllers->count; ++i)
		if (controllers->models[i].kind == AERON_CONTROLLER_KIND_GAMEPAD)
			return controllers->models[i].profile.mapping.axes[axis].invert;
	return false;
}

void TieN3dsSettings_Toggle(TieN3dsSetting setting) {
	if (setting == TIE_3DS_SETTING_GYRO) {
		TieN3dsSettings_LoadLocal();
		s_gyro = !s_gyro;
		TieN3dsSettings_SaveLocal();
		Aeron_LogInfo("tie.3ds", "gyro aiming %s", s_gyro ? "on" : "off");
		return;
	}
	TieAppConfigState* config = TieAppConfig_Current();
	const int axis = TieN3dsSettings_Axis(setting);
	if (!config || axis < 0)
		return;
	const bool invert = !TieN3dsSettings_Get(setting);
	TieControllerOptions candidate = config->requested.controller;
	bool changed = false;
	for (size_t i = 0; i < candidate.count; ++i) {
		if (candidate.models[i].kind != AERON_CONTROLLER_KIND_GAMEPAD)
			continue;
		candidate.models[i].profile.mapping.axes[axis].invert = invert;
		changed = true;
	}
	if (!changed)
		return;
	char error[512];
	if (!TieAppConfig_SetController(config, &candidate, error, sizeof error)) {
		Aeron_LogWarn("tie.3ds", "could not save the controller setting: %s", error);
		return;
	}
	TieControllerMapping_SetOptions(&config->requested.controller);
	Aeron_LogInfo("tie.3ds", "axis %d inversion %s", axis, invert ? "on" : "off");
}
