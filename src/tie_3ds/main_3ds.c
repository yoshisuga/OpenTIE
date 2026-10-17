/*
 * Nintendo 3DS entry point: starts the TIE95 game from the installation in
 * sdmc:/3ds/OpenTIE/TIE95 and presents its classic framebuffer on the top
 * screen. The bottom screen shows the log, which is also written to
 * sdmc:/3ds/OpenTIE/opentie.log.
 *
 * Mirrors tie_app/application.c and frame_loop.c without the GPU renderer,
 * remaster, settings menu and installation setup UI.
 */
#include <3ds.h>
#include <SDL3/SDL.h>

#include "aeron/aeron.h"
#include "aeron/log.h"
#include "aeron/paths.h"
#include "aeron/vfs.h"
#include "tie_app/config/app_config.h"
#include "tie_app/setup/installation.h"
#include "tie_3ds/flight_gpu_3ds.h"
#include "tie_3ds/n3ds_input.h"
#include "tie_3ds/settings_3ds.h"
#include "tie_3ds/touch_panel_3ds.h"
#include "tie/drawpol.h"
#include "tie/logbuf2.h"
#include "tie/tie.h"
#include "tie/xtrans2.h"
#include "tie_runtime/runtime/flight_screen.h"
#include "tie_runtime/display/classic_display.h"
#include "tie_runtime/display/classic_framebuffer.h"
#include "tie_runtime/display/flight_stereo.h"
#include "tie_runtime/flight_assets/service.h"
#include "tie_runtime/hooks/axis_input.h"
#include "tie_runtime/input/controller_mapping.h"
#include "tie_runtime/input/input.h"
#include "tie_runtime/input/keyboard_mapping.h"
#include "tie_runtime/input/mouse_flight.h"
#include "tie_runtime/presentation/classic_layer.h"
#include "tie_runtime/presentation/presentation.h"
#include "tie_runtime/runtime/profile.h"
#include "tie_runtime/runtime/runtime.h"
#include "tie_runtime/snapshot/snapshot.h"

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#define TIE_3DS_USER_DIR "sdmc:/3ds/OpenTIE"
#define TIE_3DS_TIE95_DIR TIE_3DS_USER_DIR "/TIE95"
#define TIE_3DS_LOG_PATH TIE_3DS_USER_DIR "/opentie.log"

/* devkitARM's default 32 KB stack is far below what the recovered engine
 * and Landru were written for; the desktop builds run with 8 MB. */
u32 __stacksize__ = 2 * 1024 * 1024;

static FILE* s_log_file;

/* The bottom screen: a two-line timing status above the scrolling log. */
static PrintConsole s_status_console;
static PrintConsole s_log_console;

typedef struct TieN3dsFrameStats {
	uint64_t window_start_us;
	uint64_t tick_us;
	uint64_t draw_us;
	uint64_t vsync_us;
	uint32_t frames;
} TieN3dsFrameStats;

static void TieN3ds_ReportFrameStats(TieN3dsFrameStats* stats, uint64_t now_us) {
	const uint64_t elapsed_us = now_us - stats->window_start_us;
	if (elapsed_us < 1000000 || stats->frames == 0)
		return;
	const double frames = stats->frames;
	if (TieN3dsTouchPanel_Active()) {
		TieN3dsTouchPanel_SetStats((float)(frames * 1e6 / (double)elapsed_us),
								   (float)((double)stats->tick_us / frames / 1000.0));
		*stats = (TieN3dsFrameStats) { .window_start_us = now_us };
		return;
	}
	consoleSelect(&s_status_console);
	printf("\x1b[1;1H%5.1f fps  tick %5.1f ms  gpu %u\x1b[K\n", frames * 1e6 / (double)elapsed_us,
		   (double)stats->tick_us / frames / 1000.0, TieN3dsFlightGpu_DrawnCount());
	printf("draw %4.1f ms  vsync wait %4.1f ms\x1b[K", (double)stats->draw_us / frames / 1000.0,
		   (double)stats->vsync_us / frames / 1000.0);
	consoleSelect(&s_log_console);
	*stats = (TieN3dsFrameStats) { .window_start_us = now_us };
}

/* Startup state lives outside main's frame. */
static TieAppConfigState s_app_config;
static TieInstallationSet s_installations;
static char s_error[768];

static void TieN3ds_LogOutput(void* userdata, int category, SDL_LogPriority priority, const char* message) {
	(void)userdata;
	(void)category;
	(void)priority;
	/* The flight control panel covers the bottom-screen console. */
	if (!TieN3dsTouchPanel_Active())
		printf("%s\n", message);
	if (s_log_file) {
		fprintf(s_log_file, "%s\n", message);
		fflush(s_log_file);
	}
}

/* Leaves the message on the bottom screen until START, since a homebrew
 * app has nowhere else to report a failure. */
static int TieN3ds_Fail(const char* title, const char* message) {
	Aeron_LogError("tie.3ds", "%s: %s", title, message);
	printf("\nPress START to exit.\n");
	while (aptMainLoop()) {
		hidScanInput();
		if (hidKeysDown() & KEY_START)
			break;
		gspWaitForVBlank();
	}
	return 1;
}

static void TieN3ds_ApplyLayout(const TiePresentationLayout* presentation) {
	if (!presentation)
		return;
	TieInput_SetClassicLayout(&presentation->frame, &presentation->classic);
	AeronN3ds_SetTouchTarget(&presentation->classic);
}

static void TieN3ds_UpdatePresentation(const AeronInputSnapshot* input, int32_t delta_us) {
	const TiePresentationChange change = TiePresentation_BeginFrame(input, delta_us);
	if (change & TIE_PRESENTATION_CHANGE_LAYOUT)
		TieN3ds_ApplyLayout(TiePresentation_Layout());
}

enum { TIE_3DS_CLASSIC_WIDTH = 320, TIE_3DS_CLASSIC_HEIGHT = 200, TIE_3DS_TEXT_MAX = 64 };

/* The frontend's pointer is not drawn into the framebuffer; the desktop
 * remaster overlays it, so the 3DS draws it over the top-screen picture. */
static void TieN3ds_DrawFrontendCursor(const TieSnapshot* snapshot) {
	if (!snapshot || !TieClassicDisplay_UsesExternalCursor() || !snapshot->cursor.visible ||
		snapshot->cursor.kind == TIE_CURSOR_NONE)
		return;
	int16_t width = 0;
	int16_t height = 0;
	const uint8_t* bitmap = TieCursorSnapshot_Bitmap(&width, &height);
	float x = 0.0f;
	float y = 0.0f;
	TieInput_CursorFramebufferPosition(&x, &y);
	const int source_width = snapshot->landru_coord_w ? snapshot->landru_coord_w : TIE_3DS_CLASSIC_WIDTH;
	const int source_height = snapshot->landru_coord_h ? snapshot->landru_coord_h : TIE_3DS_CLASSIC_HEIGHT;
	AeronN3ds_DrawCursor(bitmap, width, height, snapshot->palette, (int)x - snapshot->cursor.hot_x,
						 (int)y - snapshot->cursor.hot_y, source_width, source_height);
}

/* Outside flight, X opens the system keyboard (SELECT is the gamepad Escape
 * binding, which the menus also honor); the text goes to the game as typed
 * characters and is confirmed with Return. */
static void TieN3ds_HandleKeyboardRequest(const TieSnapshot* snapshot) {
	if ((snapshot && snapshot->scene_kind == TIE_SCENE_FLIGHT) || !(hidKeysDown() & KEY_X))
		return;
	SwkbdState keyboard;
	char text[TIE_3DS_TEXT_MAX + 1] = { 0 };
	swkbdInit(&keyboard, SWKBD_TYPE_NORMAL, 2, TIE_3DS_TEXT_MAX);
	swkbdSetHintText(&keyboard, "Text for TIE Fighter");
	if (swkbdInputText(&keyboard, text, sizeof text) == SWKBD_BUTTON_CONFIRM)
		AeronN3ds_QueueText(text, true);
}

/* ---- Stereoscopic flight ------------------------------------------------
 * flight_stereo renders the 3D scene a second time from a camera moved to
 * the right. The TIE95 rasterizer draws space only where its cockpit mask
 * allows, so the same mask tells the presenter which pixels are cockpit
 * (kept at screen depth) and which are space (moved behind the screen by
 * the convergence shift). */

/* Flight's 3D view comes from the citro3d renderer (flight_gpu_3ds) under
 * the classic cockpit and HUD, instead of the software rasterizer. */
static const bool k_gpu_flight = false;

enum {
	TIE_3DS_STEREO_CONVERGENCE = 8,   /* top-screen pixels at full slider */
	TIE_3DS_XTRANS_DATA_SIZE = 64000, /* smallest buffer xtransdataptr names */
};

static float s_stereo_strength;
static bool s_gpu_flight_active;
static uint8_t s_space_mask[TIE_3DS_CLASSIC_WIDTH * TIE_3DS_CLASSIC_HEIGHT];
static uint8_t s_right_frame[TIE_3DS_CLASSIC_WIDTH * TIE_3DS_CLASSIC_HEIGHT];

static bool TieN3ds_ReadMaskRun(const uint8_t** cursor, const uint8_t* end, int* out_run) {
	const uint8_t* p = *cursor;
	if (p >= end)
		return false;
	int run = *p++;
	if (run == 0) {
		if (p >= end)
			return false;
		run = *p++;
		if (run == 0) {
			if (p >= end)
				return false;
			run = *p++ + 256;
		}
		run += 255;
	}
	*cursor = p;
	*out_run = run;
	return true;
}

/* Decodes the mask xtrans2_drawxtrans walks: per row a signed start state,
 * then alternating runs (state >= 0 is drawn space) until the row is full. */
static bool TieN3ds_DecodeSpaceMask(void) {
	memset(s_space_mask, 0, sizeof s_space_mask);
	const int width = pixelswide;
	const int height = pixelsdeep;
	const int left = (int)displaycorner_columns;
	const int top = (int)displaycorner_lines;
	if (!xtransdataptr || width <= 0 || height <= 0 || left + width > TIE_3DS_CLASSIC_WIDTH ||
		top + height > TIE_3DS_CLASSIC_HEIGHT)
		return false;
	const uint8_t* cursor = (const uint8_t*)xtransdataptr + maskbufptr;
	const uint8_t* end = (const uint8_t*)xtransdataptr + TIE_3DS_XTRANS_DATA_SIZE;
	for (int row = 0; row < height; ++row) {
		if (cursor >= end)
			return false;
		int8_t state = (int8_t)*cursor++;
		uint8_t* line = s_space_mask + (top + row) * TIE_3DS_CLASSIC_WIDTH + left;
		for (int x = 0; x < width;) {
			int run = 0;
			if (!TieN3ds_ReadMaskRun(&cursor, end, &run))
				return false;
			const int stop = x + run < width ? x + run : width;
			if (state >= 0)
				memset(line + x, 1, (size_t)(stop - x));
			x += run;
			state = (int8_t)-state;
		}
	}
	return true;
}

/* Stereo follows the 3D slider during ordinary 320x200 cockpit flight. The
 * strength is set before the tick so its render produces both eyes. */
static void TieN3ds_BeginStereoFrame(const TieSnapshot* snapshot) {
	const bool flying = snapshot && snapshot->scene_kind == TIE_SCENE_FLIGHT &&
						snapshot->flight_screen == TIE_FLIGHT_SCREEN_NORMAL && !snapshot->replay_mode &&
						flightResolution == TIE_FLIGHT_RES_VGA;
	s_gpu_flight_active = flying && k_gpu_flight;
	s_stereo_strength = flying && !s_gpu_flight_active ? osGet3DSliderState() : 0.0f;
	TieFlightStereo_SetStrength(s_stereo_strength);
	TieFlightStereo_SetCaptureScene(s_gpu_flight_active);
}

/* In GPU flight the classic frame keeps only the cockpit and whatever the
 * panel drew after the 3D render (instruments, gunsight, brackets); the
 * rest of the 3D window is left for the GPU scene. */
static void TieN3ds_UpdateGpuFlight(void) {
	const uint8_t* scene = NULL;
	const TieFramebuffer* framebuffer = TieClassicFramebuffer_Current();
	if (!s_gpu_flight_active || !TieFlightStereo_TakeScene(&scene) || !framebuffer || !framebuffer->pixels ||
		framebuffer->width != TIE_3DS_CLASSIC_WIDTH || framebuffer->height != TIE_3DS_CLASSIC_HEIGHT ||
		!TieN3ds_DecodeSpaceMask()) {
		AeronN3ds_SetComposite(NULL, 0, 0);
		return;
	}
	for (int y = 0; y < TIE_3DS_CLASSIC_HEIGHT; ++y) {
		const uint8_t* final_row = framebuffer->pixels + y * framebuffer->pitch;
		const uint8_t* scene_row = scene + y * TIE_FLIGHT_STEREO_WIDTH;
		uint8_t* mask = s_space_mask + y * TIE_3DS_CLASSIC_WIDTH;
		for (int x = 0; x < TIE_3DS_CLASSIC_WIDTH; ++x)
			mask[x] = mask[x] && final_row[x] == scene_row[x];
	}
	AeronN3ds_SetComposite(s_space_mask, TIE_3DS_CLASSIC_WIDTH, TIE_3DS_CLASSIC_HEIGHT);
}

/* The right eye takes its 3D from the right-eye render and, wherever the
 * cockpit panel changed the left picture after its 3D render (instruments,
 * gunsight, brackets), the panel's pixels. */
static void TieN3ds_UpdateStereo(void) {
	const uint8_t* left_scene = NULL;
	const uint8_t* right_scene = NULL;
	const TieFramebuffer* framebuffer = TieClassicFramebuffer_Current();
	if (s_stereo_strength <= 0.0f || !TieFlightStereo_TakeFrame(&left_scene, &right_scene) || !framebuffer ||
		!framebuffer->pixels || framebuffer->width != TIE_3DS_CLASSIC_WIDTH ||
		framebuffer->height != TIE_3DS_CLASSIC_HEIGHT || !TieN3ds_DecodeSpaceMask()) {
		AeronN3ds_SetStereo(NULL, NULL, 0, 0, 0);
		return;
	}
	for (int y = 0; y < TIE_3DS_CLASSIC_HEIGHT; ++y) {
		const uint8_t* final_row = framebuffer->pixels + y * framebuffer->pitch;
		const uint8_t* left_row = left_scene + y * TIE_FLIGHT_STEREO_WIDTH;
		const uint8_t* right_row = right_scene + y * TIE_FLIGHT_STEREO_WIDTH;
		uint8_t* out = s_right_frame + y * TIE_3DS_CLASSIC_WIDTH;
		for (int x = 0; x < TIE_3DS_CLASSIC_WIDTH; ++x)
			out[x] = final_row[x] != left_row[x] ? final_row[x] : right_row[x];
	}
	AeronN3ds_SetStereo(s_space_mask, s_right_frame, TIE_3DS_CLASSIC_WIDTH, TIE_3DS_CLASSIC_HEIGHT,
						(int)(s_stereo_strength * TIE_3DS_STEREO_CONVERGENCE + 0.5f));
}

/* During ordinary cockpit flight the bottom screen is the control panel;
 * elsewhere it is the console and the touchscreen is the mouse. */
static void TieN3ds_UpdateTouchPanel(const TieSnapshot* snapshot) {
	const bool active = snapshot && snapshot->scene_kind == TIE_SCENE_FLIGHT &&
						snapshot->flight_screen == TIE_FLIGHT_SCREEN_NORMAL && snapshot->replay_mode != 2;
	if (active != TieN3dsTouchPanel_Active()) {
		TieN3dsTouchPanel_SetActive(active);
		AeronN3ds_SetBottomScreen(active ? TieN3dsTouchPanel_Draw : NULL);
		if (!active) {
			/* Repaint the console the panel drew over. */
			consoleSelect(&s_status_console);
			consoleClear();
			consoleSelect(&s_log_console);
			consoleClear();
		}
	}
	TieN3dsTouchPanel_Update();
	/* Gyro aiming only while flying from the cockpit. */
	AeronN3ds_SetGyroAiming(active && TieN3dsSettings_Get(TIE_3DS_SETTING_GYRO));
}

/* Binds newly connected gamepads, as tie_app/frame_loop.c does each frame;
 * the 3DS buttons and sticks arrive as SDL's built-in "Nintendo 3DS" pad. */
static void TieN3ds_DiscoverControllers(const AeronInputSnapshot* input) {
	static char previous_error[512];
	TieAppConfigState* config = TieAppConfig_Current();
	if (!config)
		return;
	TieControllerOptions candidate = config->requested.controller;
	char error[512] = { 0 };
	bool ok = TieControllerMapping_InitializeGamepads(&candidate, &config->gamepad_defaults, input, error,
													  sizeof error);
	if (!TieControllerMapping_Optionsequal(&candidate, &config->requested.controller)) {
		char save_error[512];
		if (TieAppConfig_SetController(config, &candidate, save_error, sizeof save_error)) {
			TieControllerMapping_SetOptions(&config->requested.controller);
			Aeron_LogInfo("tie.3ds", "gamepad bindings updated");
		} else {
			snprintf(error, sizeof error, "%s", save_error);
			ok = false;
		}
	}
	if (!ok && strcmp(error, previous_error))
		Aeron_LogWarn("tie.input", "%s", error);
	snprintf(previous_error, sizeof previous_error, "%s", ok ? "" : error);
}

static void TieN3ds_RunFrames(void) {
	TieN3ds_ApplyLayout(TiePresentation_Layout());
	TieClassicLayer_Init();
	TieN3dsFrameStats stats = { .window_start_us = Aeron_NowUs() };

	while (aptMainLoop() && TieRuntime_IsActive() && !TieRuntime_ShouldExit() && !Aeron_FatalErrorRequested()) {
		const int32_t delta_us = Aeron_BeginFrame();
		if (Aeron_QuitRequested())
			TieRuntime_RequestExit();
		const AeronInputSnapshot* input = Aeron_InputSnapshot();

		TieN3ds_HandleKeyboardRequest(TieSnapshot_Current());
		TieN3ds_DiscoverControllers(input);
		TieRuntime_SetWindowActive(true);
		TieN3ds_UpdatePresentation(input, delta_us);
		TieInput_UpdateCapture(TieSnapshot_Current(), false);
		TieClassicLayer_SyncInputExtent();
		TieInput_UpdateKeyboard(input, false);
		TieInput_BeginFrame(delta_us);
		TieN3ds_UpdateTouchPanel(TieSnapshot_Current());
		TieN3ds_BeginStereoFrame(TieSnapshot_Current());
		const uint64_t tick_start_us = Aeron_NowUs();
		TieRuntime_Tick(delta_us);
		const uint64_t tick_end_us = Aeron_NowUs();
		stats.tick_us += tick_end_us - tick_start_us;
		(void)TieRuntime_ConsumeSettingsMenuRequest();
		if (TieRuntime_FlightResourceReleaseRequested())
			TieRuntime_CompleteFlightResourceRelease();
		if (Aeron_FatalErrorRequested())
			break;

		const uint64_t draw_start_us = Aeron_NowUs();
		TieClassicLayer_SyncInputExtent();
		TieN3ds_UpdateStereo();
		TieN3ds_UpdateGpuFlight();
		if (TieClassicDisplay_OutputKind() == TIE_CLASSIC_OUTPUT_INDEXED_FRAMEBUFFER)
			TieClassicLayer_Submit(TieClassicFramebuffer_Current());
		TieN3ds_DrawFrontendCursor(TieSnapshot_Current());
		const uint64_t present_start_us = Aeron_NowUs();
		stats.draw_us += present_start_us - draw_start_us;
		Aeron_Present();
		const uint64_t present_end_us = Aeron_NowUs();
		stats.vsync_us += present_end_us - present_start_us;
		++stats.frames;
		TieN3ds_ReportFrameStats(&stats, present_end_us);
	}
	TieClassicLayer_Shutdown();
}

int main(void) {
	/* New 3DS: 804 MHz and the L2 cache. No effect on the original 3DS. */
	osSetSpeedupEnable(true);
	romfsInit();
	mkdir(TIE_3DS_USER_DIR, 0777);
	s_log_file = fopen(TIE_3DS_LOG_PATH, "w");
	SDL_SetLogOutputFunction(TieN3ds_LogOutput, NULL);

	const AeronConfig config = {
		.org_name = "TotallyOpen",
		.app_name = "OpenTIE",
		.resource_path = "resources",
		.shader_path = "shaders",
		.window_title = "OpenTIE",
		.logical_width = 400,
		.logical_height = 240,
	};
	/* SDL's video init (inside Aeron_Init) owns gfxInit. */
	if (!Aeron_Init(&config)) {
		gfxInitDefault();
		consoleInit(GFX_BOTTOM, NULL);
		return TieN3ds_Fail("Startup Error", "Aeron_Init failed");
	}
	consoleInit(GFX_BOTTOM, &s_status_console);
	consoleSetWindow(&s_status_console, 0, 0, 40, 2);
	consoleInit(GFX_BOTTOM, &s_log_console);
	consoleSetWindow(&s_log_console, 0, 2, 40, 28);
	consoleSelect(&s_log_console);
	Aeron_LogInfo("tie.3ds", "OpenTIE %s", TIE_VERSION_STRING);
	bool new_3ds = false;
	APT_CheckNew3DS(&new_3ds);
	Aeron_LogInfo("tie.3ds", "%s, CPU speed-up %s", new_3ds ? "New 3DS" : "3DS", new_3ds ? "on" : "unavailable");
	/* Holding SELECT at launch disables music synthesis, to measure its cost. */
	hidScanInput();
	const bool music_disabled = (hidKeysHeld() & KEY_SELECT) != 0;

	AeronVfs* vfs = Aeron_GetVfs();
	const uint32_t dos_lookup = AERON_VFS_ROOT_OPTION_CASE_INSENSITIVE_LOOKUP;
	if (!AeronVfs_SetRootOptions(vfs, AERON_VFS_ROOT_USER, dos_lookup) ||
		!AeronVfs_SetRootOptions(vfs, AERON_VFS_ROOT_TEMP, dos_lookup))
		return TieN3ds_Fail("Storage Configuration Error", "Could not configure the user storage roots.");

	char* const error = s_error;
	const size_t error_capacity = sizeof s_error;
	TieAppConfigState* const app_config_state = &s_app_config;
	TieInstallationSet* const installations = &s_installations;
	TieKeyboardMapping_SetPolicy(TIE_KEYBOARD_PLATFORM_OTHER, false);
	if (!TieAppConfig_Load(vfs, app_config_state, error, error_capacity))
		return TieN3ds_Fail("Configuration Error", error);
	TieKeyboardMapping_Install(&app_config_state->requested.keyboard);
	TieControllerMapping_SetOptions(&app_config_state->requested.controller);
	TieMouseFlight_SetOptions(&app_config_state->requested.mouse);
	TieAxisInputHook_SetEnabled(app_config_state->requested.fix_axis_input_bias);

	if (!TieInstallation_Open(&installations->tie95, TIE_GAME_VERSION_TIE95, TIE_3DS_TIE95_DIR, Aeron_ResourceRoot(),
							  error, error_capacity))
		return TieN3ds_Fail("TIE95 Installation Error", error);
	installations->has_tie95 = true;

	/* The 3DS runs TIE95 alone, with the OPL3 synthesizer and the TIE95
	 * soundtrack; the shipped defaults select TIE98. */
	app_config_state->requested.frontend_version = TIE_VERSION_SELECTION_TIE95;
	app_config_state->requested.flight_version = TIE_VERSION_SELECTION_TIE95;
	app_config_state->requested.requested_model_source = TIE_FLIGHT_MODEL_SOURCE_ORIGINAL;
	if (app_config_state->requested.music_source == TIE_MUSIC_TIE98)
		app_config_state->requested.music_source = TIE_MUSIC_IMUSE;
	if (!TieMidiBackend_Available(app_config_state->requested.midi_backend))
		app_config_state->requested.midi_backend = TIE_MIDI_BACKEND_FM4_OPL3;

	TieLaunchConfig launch_config = { 0 };
	if (!TieAppConfig_ResolveLaunch(&app_config_state->requested, true, false, &launch_config, error, error_capacity))
		return TieN3ds_Fail("Installation Selection Error", error);
	const TieFrontendProfileId frontend_profile = (TieFrontendProfileId)launch_config.frontend_version;
	TieProfile_SetFrontend(frontend_profile);
	TieProfile_SetFlight(&launch_config.flight_profile);

	const TieMidiBackendKind midi_backend =
		app_config_state->requested.music_source == TIE_MUSIC_IMUSE && !music_disabled
			? app_config_state->requested.midi_backend
			: TIE_MIDI_BACKEND_NONE;
	Aeron_LogInfo("tie.3ds", "music synthesis %s", music_disabled ? "disabled (SELECT)" : "enabled");
	const TieRuntimeConfig runtime_config = {
		.storage = {
			.application_vfs = vfs,
			.tie95_vfs = installations->tie95.vfs,
			.frontend_version = launch_config.frontend_version,
			.flight_version = launch_config.flight_profile.version,
		},
		.flight_assets = {
			.tie95_vfs = installations->tie95.vfs,
			.source = {
				.profile = launch_config.flight_profile,
				.smooth_angle_degrees = app_config_state->requested.flight_model_smooth_angle_degrees,
				.opt_emissive_strength = app_config_state->requested.flight_model_opt_emissive_strength,
				.opt_projectile_emissive_strength =
					app_config_state->requested.flight_model_opt_projectile_emissive_strength,
			},
		},
		.frontend_profile = frontend_profile,
		.flight_profile = launch_config.flight_profile,
		.audio = {
			.midi_backend = { .kind = midi_backend },
			.sb16_filter_enabled = app_config_state->requested.sb16_filter_enabled,
			.prefer_tie95_frontend_voices = app_config_state->requested.prefer_tie95_frontend_voices,
			.music_source = app_config_state->requested.music_source,
			.music_ducking_volume_percent = app_config_state->requested.music_ducking_volume_percent,
		},
	};
	if (!TieRuntime_Init(&runtime_config, error, error_capacity))
		return TieN3ds_Fail("Game Runtime Error", error);
	const TieFlightAssetSource* flight_source = TieFlightAssets_CurrentSource();
	if (!flight_source || !TiePresentation_Init(flight_source->presentation_aspect))
		return TieN3ds_Fail("Presentation Error", "Could not initialize the classic presentation.");

	if (k_gpu_flight)
		AeronN3ds_SetEyeOverlay(TieN3dsFlightGpu_DrawEye);
	Aeron_LogInfo("tie.3ds", "game started");
	TieN3ds_RunFrames();
	const bool failed = Aeron_FatalErrorRequested();

	TiePresentation_Shutdown();
	TieRuntime_Shutdown();
	TieInstallation_SetClose(installations);
	if (!TieAppConfig_Save(vfs, app_config_state, error, error_capacity))
		Aeron_LogError("tie.config", "%s", error);
	TieAppConfig_Destroy(app_config_state);
	AeronN3ds_SetEyeOverlay(NULL);
	AeronN3ds_SetBottomScreen(NULL);
	AeronN3ds_SetGyroAiming(false);
	TieN3dsTouchPanel_Shutdown();
	TieN3dsFlightGpu_Shutdown();
	if (failed)
		return TieN3ds_Fail("OpenTIE stopped", "A fatal error was reported; see the log above.");
	Aeron_Shutdown();
	if (s_log_file)
		fclose(s_log_file);
	return 0;
}
