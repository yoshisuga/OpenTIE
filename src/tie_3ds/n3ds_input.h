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

/* Draws an 8-bit cursor bitmap (index 0 transparent) over the classic picture
 * on the top screen. x/y is the bitmap's top-left in source framebuffer
 * pixels; source_width/height is the framebuffer size the picture shows. */
void AeronN3ds_DrawCursor(const uint8_t* bitmap, int width, int height, const uint32_t* palette, int x, int y,
						  int source_width, int source_height);

#endif
