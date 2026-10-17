#include "tie_runtime/display/flight_stereo.h"

#include "tie/logbuf2.h"
#include "tie/rtsvga2.h"
#include "tie/tie.h"
#include "tie/transfm2.h"
#include "tie/xtrans2.h"

#include <string.h>

/* starposbuf1/2 in rtsvga2.c: the star positions drawn in the previous and
 * current frame, used to erase the old stars. */
enum { TIE_FLIGHT_STEREO_STAR_SLOTS = 768 };

typedef struct TieFlightStereoEyeCache {
	int32_t x, y, z;
} TieFlightStereoEyeCache;

static float s_strength;
static bool s_rendering_right_eye;
static bool s_frame_ready;
static bool s_capture_scene;
static bool s_scene_ready;
static int32_t s_offset_x, s_offset_y, s_offset_z;
static uint8_t s_left_scene[TIE_FLIGHT_STEREO_WIDTH * TIE_FLIGHT_STEREO_HEIGHT];
static uint8_t s_right_scene[TIE_FLIGHT_STEREO_WIDTH * TIE_FLIGHT_STEREO_HEIGHT];
static uint8_t s_saved_logbuf[TIE_FLIGHT_STEREO_WIDTH * TIE_FLIGHT_STEREO_HEIGHT];
static int32_t s_saved_new_stars[TIE_FLIGHT_STEREO_STAR_SLOTS];
static int32_t s_saved_old_stars[TIE_FLIGHT_STEREO_STAR_SLOTS];
static int32_t s_saved_left_extent[TIE_FLIGHT_STEREO_HEIGHT];
static int32_t s_saved_right_extent[TIE_FLIGHT_STEREO_HEIGHT];

void TieFlightStereo_SetStrength(float strength) {
	s_strength = strength < 0.0f ? 0.0f : strength > 1.0f ? 1.0f : strength;
}

void TieFlightStereo_SetCaptureScene(bool capture) { s_capture_scene = capture; }

bool TieFlightStereo_TakeScene(const uint8_t** scene) {
	if (!s_scene_ready)
		return false;
	s_scene_ready = false;
	*scene = s_left_scene;
	return true;
}

void TieFlightStereo_OffsetCamera(void) {
	if (!s_rendering_right_eye)
		return;
	camera.x += s_offset_x;
	camera.y += s_offset_y;
	camera.z += s_offset_z;
}

static void TieFlightStereo_CopyFramebuffer(uint8_t* destination) {
	for (int row = 0; row < TIE_FLIGHT_STEREO_HEIGHT; ++row)
		memcpy(destination + row * TIE_FLIGHT_STEREO_WIDTH, xtrans2_videobaseptr + row * screenMemWidth,
			   TIE_FLIGHT_STEREO_WIDTH);
}

static void TieFlightStereo_RestoreFramebuffer(const uint8_t* source) {
	for (int row = 0; row < TIE_FLIGHT_STEREO_HEIGHT; ++row)
		memcpy(xtrans2_videobaseptr + row * screenMemWidth, source + row * TIE_FLIGHT_STEREO_WIDTH,
			   TIE_FLIGHT_STEREO_WIDTH);
}

/* The eye offset is camera-space +x, read from the view matrix the left
 * render just built (eye x = worldeye{A,B,C}1 . world, in Q15). */
static bool TieFlightStereo_PrepareOffset(void) {
	if (pstate.object_idx >= NUM_OBJECTS)
		return false;
	const uint16_t species = objects[pstate.object_idx].ship_idx;
	if (species == 0 || species >= NUM_SPECIES)
		return false;
	/* Wider baselines show distant ships in depth but split the player's own
	 * laser bolts, which start beside the camera, far apart between the eyes. */
	const int32_t separation = (int32_t)(s_strength * 0.125f * (float)species_table[species].bound_hwidth);
	if (separation <= 0)
		return false;
	s_offset_x = (int32_t)(((int64_t)separation * worldeyeA1) >> 15);
	s_offset_y = (int32_t)(((int64_t)separation * worldeyeB1) >> 15);
	s_offset_z = (int32_t)(((int64_t)separation * worldeyeC1) >> 15);
	return true;
}

void TieFlightStereo_AfterRender(void) {
	if (!s_rendering_right_eye && s_capture_scene && s_strength <= 0.0f && flightResolution == TIE_FLIGHT_RES_VGA &&
		screenMemWidth >= TIE_FLIGHT_STEREO_WIDTH && xtrans2_videobaseptr) {
		TieFlightStereo_CopyFramebuffer(s_left_scene);
		s_scene_ready = true;
		return;
	}
	const size_t logbuf_size = (size_t)pixelswide * pixelsdeep;
	if (s_rendering_right_eye || s_strength <= 0.0f || flightResolution != TIE_FLIGHT_RES_VGA ||
		screenMemWidth < TIE_FLIGHT_STEREO_WIDTH || !xtrans2_videobaseptr || !buffer_ptr || !newstarptr ||
		!oldstarptr || !leftside || !rightside || pixelsdeep > TIE_FLIGHT_STEREO_HEIGHT ||
		logbuf_size > sizeof s_saved_logbuf || !TieFlightStereo_PrepareOffset())
		return;

	/* State the render writes that the rest of the frame reads. */
	static Camera saved_camera;
	static TieFlightStereoEyeCache saved_eye[NUM_CRAFTS];
	saved_camera = camera;
	for (int i = 0; i < NUM_CRAFTS; ++i)
		saved_eye[i] = (TieFlightStereoEyeCache) { crafts[i].eye_x_cache, crafts[i].eye_y_cache, crafts[i].eye_z_cache };
	const int32_t saved_objecteyex = objecteyex;
	const int32_t saved_objecteyey = objecteyey;
	const int32_t saved_objecteyez = objecteyez;
	/* The renderer redraws only what changed against its record of the
	 * previous frame (the logical buffer and each row's drawn extent), and
	 * erases last frame's stars from the star position buffers; all must
	 * describe the left picture that goes back into the framebuffer. */
	memcpy(s_saved_logbuf, buffer_ptr, logbuf_size);
	memcpy(s_saved_left_extent, leftside, pixelsdeep * sizeof(int32_t));
	memcpy(s_saved_right_extent, rightside, pixelsdeep * sizeof(int32_t));
	int32_t* const saved_new_star_ptr = newstarptr;
	int32_t* const saved_old_star_ptr = oldstarptr;
	memcpy(s_saved_new_stars, newstarptr, sizeof s_saved_new_stars);
	memcpy(s_saved_old_stars, oldstarptr, sizeof s_saved_old_stars);

	TieFlightStereo_CopyFramebuffer(s_left_scene);
	s_rendering_right_eye = true;
	tie_updatescreen();
	s_rendering_right_eye = false;
	TieFlightStereo_CopyFramebuffer(s_right_scene);
	TieFlightStereo_RestoreFramebuffer(s_left_scene);

	camera = saved_camera;
	for (int i = 0; i < NUM_CRAFTS; ++i) {
		crafts[i].eye_x_cache = saved_eye[i].x;
		crafts[i].eye_y_cache = saved_eye[i].y;
		crafts[i].eye_z_cache = saved_eye[i].z;
	}
	objecteyex = saved_objecteyex;
	objecteyey = saved_objecteyey;
	objecteyez = saved_objecteyez;
	memcpy(buffer_ptr, s_saved_logbuf, logbuf_size);
	memcpy(leftside, s_saved_left_extent, pixelsdeep * sizeof(int32_t));
	memcpy(rightside, s_saved_right_extent, pixelsdeep * sizeof(int32_t));
	newstarptr = saved_new_star_ptr;
	oldstarptr = saved_old_star_ptr;
	memcpy(newstarptr, s_saved_new_stars, sizeof s_saved_new_stars);
	memcpy(oldstarptr, s_saved_old_stars, sizeof s_saved_old_stars);
	s_frame_ready = true;
}

bool TieFlightStereo_TakeFrame(const uint8_t** left_scene, const uint8_t** right_scene) {
	if (!s_frame_ready)
		return false;
	s_frame_ready = false;
	*left_scene = s_left_scene;
	*right_scene = s_right_scene;
	return true;
}
