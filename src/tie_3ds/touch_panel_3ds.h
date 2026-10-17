#ifndef TIE_3DS_TOUCH_PANEL_3DS_H
#define TIE_3DS_TOUCH_PANEL_3DS_H

#include <stdbool.h>

/* The bottom-screen flight control panel: a tab bar of pages (MAIN, PWR,
 * TGT, VIEW, INFO, CMD, MSN, SAVE, SYS) over a grid of buttons that send the
 * game's input actions, after the iOS touch overlay. */

/* Shown during ordinary cockpit flight; elsewhere the touchscreen is the
 * mouse. Turning it off releases any held button. */
void TieN3dsTouchPanel_SetActive(bool active);
bool TieN3dsTouchPanel_Active(void);

/* Reads the touchscreen and sends actions. Call each frame after the input
 * snapshot is taken and before the game ticks. */
void TieN3dsTouchPanel_Update(void);

/* The frame rate and the game's tick time shown in the status strip. */
void TieN3dsTouchPanel_SetStats(float fps, float tick_ms);

/* Draws the panel; called with the bottom-screen target bound. */
void TieN3dsTouchPanel_Draw(void);

void TieN3dsTouchPanel_Shutdown(void);

#endif
