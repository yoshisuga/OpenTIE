#ifndef TIE_RUNTIME_DISPLAY_FLIGHT_STEREO_H
#define TIE_RUNTIME_DISPLAY_FLIGHT_STEREO_H

#include <stdbool.h>
#include <stdint.h>

/* Stereoscopic TIE95 flight: after the normal (left-eye) 3D render,
 * tie_updatescreen renders the scene again from a camera moved along its
 * right axis, keeps that picture as the right eye, and restores the left
 * picture and every piece of state the render touches, so the game sees a
 * single camera per frame. Only the 320x200 software path is supported. */
enum { TIE_FLIGHT_STEREO_WIDTH = 320, TIE_FLIGHT_STEREO_HEIGHT = 200 };

/* 0 disables; 1 is the full eye separation (an eighth of the player
 * craft's half-width). */
void TieFlightStereo_SetStrength(float strength);

/* tie_updatescreen hooks: before the scene is drawn, and after it is. */
void TieFlightStereo_OffsetCamera(void);
void TieFlightStereo_AfterRender(void);

/* Also keep the 3D-only picture of each 320x200 render when not in stereo,
 * for presenters that replace the 3D view but keep the cockpit and HUD. */
void TieFlightStereo_SetCaptureScene(bool capture);
bool TieFlightStereo_TakeScene(const uint8_t** scene);

/* The 3D-only left and right pictures (320x200, pitch 320) of the latest
 * stereo render, if one happened since the last call. The left picture is
 * the framebuffer before the cockpit panel drew over it. */
bool TieFlightStereo_TakeFrame(const uint8_t** left_scene, const uint8_t** right_scene);

#endif
