#ifndef TIE_3DS_SETTINGS_3DS_H
#define TIE_3DS_SETTINGS_3DS_H

#include <stdbool.h>

/* OpenTIE settings changeable on the 3DS, which has no settings menu. Stick
 * inversion is saved in the app configuration; 3DS-only settings (gyro
 * aiming) in sdmc:/3ds/OpenTIE/3ds_settings.txt. */
typedef enum TieN3dsSetting {
	TIE_3DS_SETTING_INVERT_PITCH,
	TIE_3DS_SETTING_INVERT_YAW,
	TIE_3DS_SETTING_INVERT_ROLL,
	TIE_3DS_SETTING_GYRO,
	TIE_3DS_SETTING_COUNT,
} TieN3dsSetting;

bool TieN3dsSettings_Get(TieN3dsSetting setting);
void TieN3dsSettings_Toggle(TieN3dsSetting setting);

#endif
