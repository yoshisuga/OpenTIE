/*
 * Aeron GPU, window and DirectDraw seam for the Nintendo 3DS port.
 *
 * The desktop implementations live in aeron/src/window.c, render_backend.c,
 * compat/ddraw.c, compat/winmm_audio.c and the scene/asset model builders,
 * all of which need SDL_GPU or FFmpeg. The 3DS has no window and presents
 * the classic indexed framebuffer on the top screen with citro2d, so the
 * window reports the top screen and only pixel layers are drawn. The TIE98 DirectDraw,
 * CD-audio and 3D-model paths are unavailable and report failure.
 */
#include "aeron/aeron.h"
#include "aeron/asset/flight_model.h"
#include "aeron/asset/opt_model.h"
#include "aeron/compat/host.h"
#include "aeron/compat/mmsystem.h"
#include "aeron/log.h"
#include "aeron/render.h"
#include "aeron/time.h"
#include "internal.h"
#include "tie_3ds/n3ds_input.h"

#include <3ds.h>
#include <citro2d.h>
#include <citro3d.h>
#include <string.h>

enum { TIE_3DS_TOP_WIDTH = 400, TIE_3DS_TOP_HEIGHT = 240 };

/* The classic picture is scaled to 4:3 at the top screen's full height. */
enum { TIE_3DS_PICTURE_WIDTH = 320, TIE_3DS_PICTURE_X = (TIE_3DS_TOP_WIDTH - TIE_3DS_PICTURE_WIDTH) / 2 };

/* ---- Touchscreen pointer --------------------------------------------- */

enum { TIE_3DS_TOUCH_WIDTH = 320, TIE_3DS_TOUCH_HEIGHT = 240 };

static AeronRectI s_touch_target;
static bool s_touch_down;
static bool s_click_pending;
static bool s_release_pending;
static uint32_t s_click_button;

void AeronN3ds_SetTouchTarget(const AeronRectI* rect) {
	if (rect)
		s_touch_target = *rect;
}

static void TieN3ds_PressButton(AeronMouseSnapshot* mouse, uint32_t button) {
	mouse->buttons |= button;
	mouse->pressed_buttons |= button;
}

static void TieN3ds_ReleaseButton(AeronMouseSnapshot* mouse, uint32_t button) {
	mouse->buttons &= ~button;
	mouse->released_buttons |= button;
}

/* The bottom screen is an absolute pointer over the classic picture. A touch
 * moves the pointer first and presses on the following frame, so the game
 * sees the pointer arrive before the click; L held at touch-down makes it a
 * right click. SDL's event pump has already scanned the HID state. */
static void TieN3ds_UpdateTouchPointer(AeronMouseSnapshot* mouse) {
	const u32 held = hidKeysHeld();
	if (held & KEY_TOUCH) {
		touchPosition touch;
		hidTouchRead(&touch);
		mouse->raw_x = touch.px;
		mouse->raw_y = touch.py;
		if (s_touch_target.width > 0 && s_touch_target.height > 0) {
			mouse->x = s_touch_target.x + touch.px * s_touch_target.width / TIE_3DS_TOUCH_WIDTH;
			mouse->y = s_touch_target.y + touch.py * s_touch_target.height / TIE_3DS_TOUCH_HEIGHT;
			mouse->inside_content = 1;
		}
		if (!s_touch_down) {
			s_touch_down = true;
			s_click_button = (held & KEY_L) ? AERON_MOUSE_BUTTON_RIGHT : AERON_MOUSE_BUTTON_LEFT;
			s_click_pending = true;
		} else if (s_click_pending) {
			TieN3ds_PressButton(mouse, s_click_button);
			s_click_pending = false;
		}
	} else if (s_touch_down) {
		s_touch_down = false;
		if (s_click_pending) {
			/* A one-frame tap: press now and release next frame. */
			TieN3ds_PressButton(mouse, s_click_button);
			s_click_pending = false;
			s_release_pending = true;
		} else {
			TieN3ds_ReleaseButton(mouse, s_click_button);
		}
	} else if (s_release_pending) {
		TieN3ds_ReleaseButton(mouse, s_click_button);
		s_release_pending = false;
	}
}

/* ---- Software-keyboard text ------------------------------------------ */

static char s_queued_text[AERON_TEXT_INPUT_CAPACITY];
static bool s_text_pending;
static bool s_return_pending;
static bool s_return_after_text;

void AeronN3ds_QueueText(const char* text, bool press_return) {
	Aeron_CopyString(s_queued_text, sizeof s_queued_text, text);
	s_text_pending = s_queued_text[0] != '\0';
	s_return_after_text = press_return;
	s_return_pending = press_return && !s_text_pending;
}

/* The game consumes typed keys before text within a frame, so the text and
 * the Return that confirms it go out on consecutive frames. */
static void TieN3ds_DeliverQueuedText(AeronInputSnapshot* input) {
	if (s_text_pending) {
		const size_t length = strlen(s_queued_text);
		memcpy(input->text, s_queued_text, length + 1);
		input->text_length = (uint32_t)length;
		s_text_pending = false;
		s_return_pending = s_return_after_text;
	} else if (s_return_pending) {
		input->key_typed[AERON_KEY_RETURN] = 1;
		s_return_pending = false;
	}
}

/* ---- Frame and events (desktop: events.c) ---------------------------- */

void Aeron_PumpEvents(void) {
	SDL_Event event;
	if (!g_aeron.initialized)
		return;
	while (SDL_PollEvent(&event))
		Aeron_HandleEvent(&event);
}

int32_t Aeron_BeginFrame(void) {
	if (!g_aeron.initialized)
		return 0;
	Aeron_BeginInputFrame(&g_aeron.input);
	Aeron_PumpEvents();
	Aeron_UpdateControllers(&g_aeron.input);
	TieN3ds_UpdateTouchPointer(&g_aeron.input.mouse);
	TieN3ds_DeliverQueuedText(&g_aeron.input);
	g_aeron.input.window_width = TIE_3DS_TOP_WIDTH;
	g_aeron.input.window_height = TIE_3DS_TOP_HEIGHT;
	g_aeron.input.has_focus = 1;

	const uint64_t now_us = Aeron_NowUs();
	uint64_t delta_us = now_us - g_aeron.last_frame_us;
	if (delta_us > AERON_MAX_DELTA_US)
		delta_us = AERON_MAX_DELTA_US;
	g_aeron.last_frame_us = now_us;
	return (int32_t)delta_us;
}

/* ---- GPU presentation ------------------------------------------------
 * The classic frame is converted once per frame straight into an RGBA8
 * texture in the GPU's tiled layout, and drawn scaled to 4:3 on the top
 * screen with citro2d. Texture sets alternate, so the CPU never writes one
 * the GPU may still be drawing. In stereo the right eye has its own picture
 * (rendered from a camera moved to the right), and alpha marks cockpit
 * (255) versus space (0): each eye draws its space shifted by half the
 * convergence, which places the far distance behind the screen, and then
 * its cockpit in place. */

enum {
	TIE_3DS_TEXTURE_WIDTH = 512,
	TIE_3DS_TEXTURE_HEIGHT = 256,
	TIE_3DS_TEXTURE_SETS = 2,
	TIE_3DS_PICTURE_HEIGHT = TIE_3DS_TOP_HEIGHT,
};

typedef struct TieN3dsPresenter {
	bool initialized;
	bool failed;
	C3D_RenderTarget* left;
	C3D_RenderTarget* right;
	C3D_Tex textures[TIE_3DS_TEXTURE_SETS][2]; /* [set][eye] */
	int current;                               /* set holding the frame to present */
	Tex3DS_SubTexture subtexture;
	/* Texel index of image column x / row y (row 0 at the top) within the
	 * tiled texture: 8x8 tiles of Morton-ordered texels, starting with the
	 * row the subtexture's top edge samples. A texel's index is
	 * column_offset[x] + row_offset[y]. */
	uint32_t column_offset[TIE_3DS_TEXTURE_WIDTH];
	uint32_t row_offset[TIE_3DS_TEXTURE_HEIGHT];
	int frame_width;
	int frame_height;
	bool frame_ready;
	bool frame_stereo; /* this frame has a right-eye picture and a cockpit mask */
	bool output_3d;
} TieN3dsPresenter;

static TieN3dsPresenter s_presenter;

static const uint8_t* s_stereo_mask;
static const uint8_t* s_stereo_right;
static int s_stereo_width;
static int s_stereo_height;
static int s_stereo_convergence;

void AeronN3ds_SetStereo(const uint8_t* space_mask, const uint8_t* right_frame, int width, int height,
						 int convergence) {
	const bool enabled = space_mask && right_frame;
	s_stereo_mask = enabled ? space_mask : NULL;
	s_stereo_right = enabled ? right_frame : NULL;
	s_stereo_width = width;
	s_stereo_height = height;
	s_stereo_convergence = enabled ? convergence : 0;
}

/* Within an 8x8 tile, texel bits interleave as y2 x2 y1 x1 y0 x0. */
static uint32_t TieN3ds_MortonX(uint32_t x) { return (x & 1u) | ((x & 2u) << 1) | ((x & 4u) << 2); }
static uint32_t TieN3ds_MortonY(uint32_t y) { return ((y & 1u) << 1) | ((y & 2u) << 2) | ((y & 4u) << 3); }

/* A top-screen render target whose output transfer writes the screen's
 * actual pixel format: SDL's video init leaves the top screen in RGBA8,
 * while C2D_CreateScreenTarget assumes libctru's default BGR8. */
static C3D_RenderTarget* TieN3ds_CreateTopTarget(gfx3dSide_t side) {
	GX_TRANSFER_FORMAT output;
	switch (gfxGetScreenFormat(GFX_TOP)) {
		case GSP_RGBA8_OES:
			output = GX_TRANSFER_FMT_RGBA8;
			break;
		case GSP_BGR8_OES:
			output = GX_TRANSFER_FMT_RGB8;
			break;
		case GSP_RGB565_OES:
			output = GX_TRANSFER_FMT_RGB565;
			break;
		case GSP_RGB5_A1_OES:
			output = GX_TRANSFER_FMT_RGB5A1;
			break;
		default:
			output = GX_TRANSFER_FMT_RGBA4;
			break;
	}
	C3D_RenderTarget* target =
		C3D_RenderTargetCreate(TIE_3DS_TOP_HEIGHT, TIE_3DS_TOP_WIDTH, GPU_RB_RGBA8, GPU_RB_DEPTH16);
	if (target)
		C3D_RenderTargetSetOutput(target, GFX_TOP, side,
								  GX_TRANSFER_FLIP_VERT(0) | GX_TRANSFER_OUT_TILED(0) | GX_TRANSFER_RAW_COPY(0) |
									  GX_TRANSFER_IN_FORMAT(GX_TRANSFER_FMT_RGBA8) |
									  GX_TRANSFER_OUT_FORMAT(output) | GX_TRANSFER_SCALING(GX_TRANSFER_SCALE_NO));
	return target;
}

/* citro3d starts after SDL's video init has set up the screens. */
static bool TieN3ds_PresenterInit(void) {
	if (s_presenter.initialized || s_presenter.failed)
		return s_presenter.initialized;
	s_presenter.failed = true;
	if (!C3D_Init(C3D_DEFAULT_CMDBUF_SIZE))
		return false;
	if (!C2D_Init(C2D_DEFAULT_MAX_OBJECTS)) {
		C3D_Fini();
		return false;
	}
	C2D_Prepare();
	s_presenter.left = TieN3ds_CreateTopTarget(GFX_LEFT);
	s_presenter.right = TieN3ds_CreateTopTarget(GFX_RIGHT);
	C3D_Tex* textures = &s_presenter.textures[0][0];
	const int texture_count = TIE_3DS_TEXTURE_SETS * 2;
	int created = 0;
	while (created < texture_count &&
		   C3D_TexInit(&textures[created], TIE_3DS_TEXTURE_WIDTH, TIE_3DS_TEXTURE_HEIGHT, GPU_RGBA8)) {
		C3D_TexSetFilter(&textures[created], GPU_NEAREST, GPU_NEAREST);
		memset(textures[created].data, 0, textures[created].size);
		++created;
	}
	if (!s_presenter.left || !s_presenter.right || created < texture_count) {
		while (created > 0)
			C3D_TexDelete(&textures[--created]);
		C2D_Fini();
		C3D_Fini();
		return false;
	}
	for (uint32_t x = 0; x < TIE_3DS_TEXTURE_WIDTH; ++x)
		s_presenter.column_offset[x] = (x & ~7u) * 8u + TieN3ds_MortonX(x);
	for (uint32_t y = 0; y < TIE_3DS_TEXTURE_HEIGHT; ++y)
		s_presenter.row_offset[y] = (y >> 3) * TIE_3DS_TEXTURE_WIDTH * 8u + TieN3ds_MortonY(y);
	s_presenter.failed = false;
	s_presenter.initialized = true;
	return true;
}

static void TieN3ds_PresenterShutdown(void) {
	if (!s_presenter.initialized)
		return;
	C3D_Tex* textures = &s_presenter.textures[0][0];
	for (int i = 0; i < TIE_3DS_TEXTURE_SETS * 2; ++i)
		C3D_TexDelete(&textures[i]);
	C2D_Fini();
	C3D_Fini();
	memset(&s_presenter, 0, sizeof s_presenter);
}

static uint32_t* TieN3ds_CurrentTexels(int eye) {
	return (uint32_t*)s_presenter.textures[s_presenter.current][eye].data;
}

/* Writes one indexed picture into a texture, decimating pictures larger
 * than the texture. With a cockpit mask, space pixels get alpha 0. */
static void TieN3ds_WritePicture(uint32_t* texels, const uint8_t* pixels, int pitch, int step_x, int step_y,
								 int width, int height, const uint32_t* palette, const uint8_t* space_mask) {
	const uint32_t* column_offset = s_presenter.column_offset;
	for (int y = 0; y < height; ++y) {
		const uint8_t* row = pixels + y * step_y * pitch;
		uint32_t* out = texels + s_presenter.row_offset[y];
		if (space_mask) {
			const uint8_t* mask = space_mask + y * width;
			for (int x = 0; x < width; ++x)
				out[column_offset[x]] = palette[row[x]] | (mask[x] ? 0x00u : 0xFFu);
		} else {
			for (int x = 0; x < width; ++x)
				out[column_offset[x]] = palette[row[x * step_x]] | 0xFFu;
		}
	}
}

static void TieN3ds_UploadFrame(const AeronPixelFrameView* frame) {
	if (!TieN3ds_PresenterInit())
		return;
	s_presenter.current = (s_presenter.current + 1) % TIE_3DS_TEXTURE_SETS;
	uint32_t palette[256];
	for (int i = 0; i < 256; ++i) {
		const AeronPaletteEntry entry = frame->palette[i];
		palette[i] = ((uint32_t)entry.r << 24) | ((uint32_t)entry.g << 16) | ((uint32_t)entry.b << 8);
	}
	const int step_x = (frame->width + TIE_3DS_TEXTURE_WIDTH - 1) / TIE_3DS_TEXTURE_WIDTH;
	const int step_y = (frame->height + TIE_3DS_TEXTURE_HEIGHT - 1) / TIE_3DS_TEXTURE_HEIGHT;
	const int width = frame->width / step_x;
	const int height = frame->height / step_y;
	const bool stereo = s_stereo_mask && frame->width == s_stereo_width && frame->height == s_stereo_height;
	TieN3ds_WritePicture(TieN3ds_CurrentTexels(0), (const uint8_t*)frame->pixels, frame->pitch, step_x, step_y,
						 width, height, palette, stereo ? s_stereo_mask : NULL);
	if (stereo)
		TieN3ds_WritePicture(TieN3ds_CurrentTexels(1), s_stereo_right, frame->width, 1, 1, width, height, palette,
							 s_stereo_mask);
	s_presenter.frame_width = width;
	s_presenter.frame_height = height;
	s_presenter.frame_stereo = stereo;
	s_presenter.frame_ready = true;
}

static void TieN3ds_DrawEye(C3D_RenderTarget* target, int eye, float space_shift) {
	C2D_TargetClear(target, C2D_Color32(0, 0, 0, 255));
	C2D_SceneBegin(target);
	if (!s_presenter.frame_ready)
		return;
	const C2D_Image image = { &s_presenter.textures[s_presenter.current][eye], &s_presenter.subtexture };
	const float scale_x = (float)TIE_3DS_PICTURE_WIDTH / (float)s_presenter.frame_width;
	const float scale_y = (float)TIE_3DS_PICTURE_HEIGHT / (float)s_presenter.frame_height;
	const float x = (float)TIE_3DS_PICTURE_X;
	if (!s_presenter.frame_stereo) {
		C2D_DrawImageAt(image, x, 0.0f, 0.5f, NULL, scale_x, scale_y);
		C2D_Flush();
		return;
	}
	/* Replace rather than blend, so alpha only selects cockpit or space. */
	C3D_AlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD, GPU_ONE, GPU_ZERO, GPU_ONE, GPU_ZERO);
	C3D_AlphaTest(true, GPU_LESS, 0x80);
	C2D_DrawImageAt(image, x + space_shift, 0.0f, 0.5f, NULL, scale_x, scale_y);
	C2D_Flush();
	C3D_AlphaTest(true, GPU_GREATER, 0x7F);
	C2D_DrawImageAt(image, x, 0.0f, 0.5f, NULL, scale_x, scale_y);
	C2D_Flush();
	C3D_AlphaTest(false, GPU_ALWAYS, 0);
	C3D_AlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD, GPU_SRC_ALPHA, GPU_ONE_MINUS_SRC_ALPHA, GPU_SRC_ALPHA,
				   GPU_ONE_MINUS_SRC_ALPHA);
}

/* Far space sits behind the screen when each eye sees it displaced outward:
 * left eye to the left, right eye to the right. */
int Aeron_Present(void) {
	if (!TieN3ds_PresenterInit()) {
		Aeron_RequestFatalRendererError("citro3d initialization");
		return 0;
	}
	const bool output_3d = s_presenter.frame_ready && s_presenter.frame_stereo;
	if (output_3d != s_presenter.output_3d) {
		gfxSet3D(output_3d);
		s_presenter.output_3d = output_3d;
	}
	/* The bottom-screen console writes through the CPU cache. */
	gfxFlushBuffers();
	C3D_FrameBegin(C3D_FRAME_SYNCDRAW);
	if (s_presenter.frame_ready) {
		for (int eye = 0; eye < (output_3d ? 2 : 1); ++eye) {
			const C3D_Tex* texture = &s_presenter.textures[s_presenter.current][eye];
			GSPGPU_FlushDataCache(texture->data, texture->size);
		}
		s_presenter.subtexture = (Tex3DS_SubTexture) {
			.width = (u16)s_presenter.frame_width,
			.height = (u16)s_presenter.frame_height,
			.left = 0.0f,
			.top = 1.0f,
			.right = (float)s_presenter.frame_width / TIE_3DS_TEXTURE_WIDTH,
			.bottom = 1.0f - (float)s_presenter.frame_height / TIE_3DS_TEXTURE_HEIGHT,
		};
	}
	const float half = (float)s_stereo_convergence * 0.5f;
	TieN3ds_DrawEye(s_presenter.left, 0, output_3d ? -half : 0.0f);
	if (output_3d)
		TieN3ds_DrawEye(s_presenter.right, 1, half);
	C3D_FrameEnd(0);
	return 1;
}

/* ---- Window ---------------------------------------------------------- */

int Aeron_WindowInit(const AeronConfig* config) {
	(void)config;
	return 1;
}

void Aeron_WindowShutdown(void) {}

void Aeron_ApplyPendingWindowAspectRatio(void) {}

int Aeron_SetLogicalSize(int width, int height) {
	(void)width;
	(void)height;
	return 1;
}

int Aeron_GetWindowSize(int* width, int* height) {
	if (width)
		*width = TIE_3DS_TOP_WIDTH;
	if (height)
		*height = TIE_3DS_TOP_HEIGHT;
	return 1;
}

int Aeron_GetPresentationPixelSize(int* width, int* height) { return Aeron_GetWindowSize(width, height); }

int Aeron_SetWindowAspectRatio(int aspect_width, int aspect_height) {
	(void)aspect_width;
	(void)aspect_height;
	return 1;
}

int Aeron_ResizeWindowToAspect(int aspect_width, int aspect_height) {
	(void)aspect_width;
	(void)aspect_height;
	return 1;
}

int Aeron_SetHostCursorVisible(int visible) {
	(void)visible;
	return 1;
}

int Aeron_SetRelativeMouseMode(int enabled) {
	(void)enabled;
	return 1;
}

int Aeron_WarpMouseLogical(int x, int y) {
	(void)x;
	(void)y;
	return 1;
}

/* ---- Render backend -------------------------------------------------- */

int Aeron_RenderBackendInit(void) { return 1; }

void Aeron_RenderBackendShutdown(void) { TieN3ds_PresenterShutdown(); }

void Aeron_OnOutputHdrStateChanged(void) {}

void Aeron_RequestFatalRendererError(const char* operation) {
	Aeron_LogError("aeron.render", "fatal renderer error: %s", operation ? operation : "(unknown)");
	g_aeron.fatal_error_requested = 1;
}

AeronTexture* Aeron_CreateTexture(const AeronTextureDesc* desc) {
	(void)desc;
	return NULL;
}

void Aeron_DestroyTexture(AeronTexture* texture) { (void)texture; }

int Aeron_UploadTextureDataCmd(AeronCommandBuffer* command_buffer, const AeronTextureUploadDesc* desc) {
	(void)command_buffer;
	(void)desc;
	return 0;
}

/* Composites the cursor into this frame's image (after the frame upload),
 * at cockpit depth. */
void AeronN3ds_DrawCursor(const uint8_t* bitmap, int width, int height, const uint32_t* palette, int x, int y,
						  int source_width, int source_height) {
	if (!bitmap || !palette || width <= 0 || height <= 0 || source_width <= 0 || source_height <= 0 ||
		!s_presenter.frame_ready)
		return;
	uint32_t* texels = TieN3ds_CurrentTexels(0);
	for (int row = 0; row < height; ++row) {
		const int sy = y + row;
		if (sy < 0 || sy >= source_height)
			continue;
		uint32_t* out = texels + s_presenter.row_offset[sy * s_presenter.frame_height / source_height];
		for (int column = 0; column < width; ++column) {
			const uint8_t index = bitmap[row * width + column];
			const int sx = x + column;
			if (index == 0 || sx < 0 || sx >= source_width)
				continue;
			const uint32_t rgb = palette[index];
			out[s_presenter.column_offset[sx * s_presenter.frame_width / source_width]] =
				((rgb >> 16) & 0xFFu) << 24 | ((rgb >> 8) & 0xFFu) << 16 | (rgb & 0xFFu) << 8 | 0xFFu;
		}
	}
}

AeronRenderSubmission Aeron_SubmitPixelLayer(const AeronPixelLayerDesc* desc) {
	if (!desc || !desc->frame.pixels || !desc->frame.palette || desc->frame.format != AERON_PIXEL_FORMAT_INDEX8 ||
		desc->frame.width <= 0 || desc->frame.height <= 0)
		return 0;
	static int logged_width;
	static int logged_height;
	if (desc->frame.width != logged_width || desc->frame.height != logged_height) {
		logged_width = desc->frame.width;
		logged_height = desc->frame.height;
		Aeron_LogInfo("tie.3ds", "classic frame %dx%d", logged_width, logged_height);
	}
	TieN3ds_UploadFrame(&desc->frame);
	return 1;
}

AeronRenderSubmission Aeron_SubmitTextureLayer(const AeronTextureLayerDesc* desc) {
	(void)desc;
	return 0;
}

/* ---- TIE98 DirectDraw ------------------------------------------------ */

HRESULT AERON_DXAPI DirectDrawCreate(const DxGuid* driver, IDirectDraw** out, void* outer) {
	(void)driver;
	(void)outer;
	if (out)
		*out = NULL;
	return DX_E_FAIL;
}

void AeronDx5_SetClassicFlightRenderingSuppressed(int suppressed) { (void)suppressed; }

void AeronDx5_CommitDepthSurfaceRect(IDirectDrawSurface* surface, const AeronDx5Rect* rect) {
	(void)surface;
	(void)rect;
}

int AeronDx5_ComposeSurfaceOverRenderTarget(IDirectDrawSurface* dst, int dst_x, int dst_y, IDirectDrawSurface* src,
											const uint8_t* coverage, int coverage_pitch) {
	(void)dst;
	(void)dst_x;
	(void)dst_y;
	(void)src;
	(void)coverage;
	(void)coverage_pitch;
	return 0;
}

/* ---- TIE98 CD audio (WinMM MCI and aux) ------------------------------ */

MMRESULT AERON_WINMMAPI mciSendCommandA(MCIDEVICEID device_id, uint32_t message, MciDwordPtr flags, void* params) {
	(void)device_id;
	(void)message;
	(void)flags;
	(void)params;
	return MCIERR_UNSUPPORTED_FUNCTION;
}

uint32_t AERON_WINMMAPI auxGetNumDevs(void) { return 0; }

MMRESULT AERON_WINMMAPI auxGetDevCapsA(uintptr_t device_id, AUXCAPSA* caps, uint32_t size) {
	(void)device_id;
	(void)caps;
	(void)size;
	return MMSYSERR_BADDEVICEID;
}

MMRESULT AERON_WINMMAPI auxGetVolume(uintptr_t device_id, uint32_t* volume) {
	(void)device_id;
	(void)volume;
	return MMSYSERR_BADDEVICEID;
}

MMRESULT AERON_WINMMAPI auxSetVolume(uintptr_t device_id, uint32_t volume) {
	(void)device_id;
	(void)volume;
	return MMSYSERR_BADDEVICEID;
}

/* ---- TIE98 3D models ------------------------------------------------- */

bool Aeron_OptModelBuildMemory(const void* bytes, size_t size, const char* label,
							   const AeronOptModelBuildOptions* options, AeronFlightModel* out,
							   AeronOptModelError* error) {
	(void)bytes;
	(void)size;
	(void)label;
	(void)options;
	if (out)
		memset(out, 0, sizeof *out);
	if (error) {
		error->code = -1;
		strncpy(error->message, "OPT models are unavailable on Nintendo 3DS", sizeof error->message - 1);
		error->message[sizeof error->message - 1] = '\0';
	}
	return false;
}

bool Aeron_FlightModelBuildMemory(const void* bytes, size_t size, const char* source_label,
								  AeronFlightModel* out) {
	(void)bytes;
	(void)size;
	(void)source_label;
	if (out)
		memset(out, 0, sizeof *out);
	return false;
}

void Aeron_FlightModelReleaseRenderData(AeronFlightModel* model) { (void)model; }

void Aeron_FlightModelFree(AeronFlightModel* model) { (void)model; }
