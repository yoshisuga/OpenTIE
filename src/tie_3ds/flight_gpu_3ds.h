#ifndef TIE_3DS_FLIGHT_GPU_3DS_H
#define TIE_3DS_FLIGHT_GPU_3DS_H

#include <stdbool.h>

/* Draws the flight scene's craft with the 3DS GPU from the current
 * snapshot into the bound top-screen render target. eye is 0 (left) or 1
 * (right). */
void TieN3dsFlightGpu_DrawEye(int eye);

/* Craft drawn in the most recent eye. */
unsigned TieN3dsFlightGpu_DrawnCount(void);

void TieN3dsFlightGpu_Shutdown(void);

#endif
