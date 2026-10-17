#ifndef TIE_3DS_N3DS_INPUT_H
#define TIE_3DS_N3DS_INPUT_H

#include "aeron/render.h"

#include <stdbool.h>
#include <stdint.h>

/* Sets the logical rectangle the bottom touchscreen maps onto as the mouse
 * pointer: the classic picture's presentation rectangle. */
void AeronN3ds_SetTouchTarget(const AeronRectI* rect);

/* Delivers text to the game as typed characters on the next frame, followed
 * by Return on the frame after when press_return is set. */
void AeronN3ds_QueueText(const char* text, bool press_return);

/* Shows the next classic frame in stereo: the frame itself is the left eye
 * and right_frame (same size and palette, pitch = width) the right. The
 * space_mask has one byte per pixel, nonzero where the pixel is space
 * rather than cockpit; cockpit stays at screen depth while each eye's space
 * moves half of convergence top-screen pixels outward. NULL pointers return
 * to a single 2D image. */
void AeronN3ds_SetStereo(const uint8_t* space_mask, const uint8_t* right_frame, int width, int height,
						 int convergence);

/* Shows the next classic frame over GPU content: pixels whose space_mask
 * byte is nonzero are left out, so whatever the eye overlay drew shows
 * through them. NULL turns compositing off. Not combined with stereo. */
void AeronN3ds_SetComposite(const uint8_t* space_mask, int width, int height);

/* Called while each eye's top-screen target is bound, after the classic
 * picture is drawn, to draw GPU content on top; when compositing, it is
 * called before the classic picture instead. eye is 0 (left) or 1. */
void AeronN3ds_SetEyeOverlay(void (*draw)(int eye));

/* While set, the bottom screen is drawn by draw (citro2d, 320 x 240) each
 * frame instead of showing the text console, and the touchscreen no longer
 * acts as the mouse. NULL returns to the console and touch mouse. */
void AeronN3ds_SetBottomScreen(void (*draw)(void));

/* Gyro aiming: while active, the console's rotation rate deflects the first
 * gamepad's left stick (turning the console turns the ship, and stopping
 * stops it), added to the Circle Pad. */
void AeronN3ds_SetGyroAiming(bool active);

/* Draws an 8-bit cursor bitmap (index 0 transparent) over the classic picture
 * on the top screen. x/y is the bitmap's top-left in source framebuffer
 * pixels; source_width/height is the framebuffer size the picture shows. */
void AeronN3ds_DrawCursor(const uint8_t* bitmap, int width, int height, const uint32_t* palette, int x, int y,
						  int source_width, int source_height);

#endif
