/*
 * Bottom-screen flight control panel for the Nintendo 3DS port.
 *
 * The SYS page holds OpenTIE settings (settings_3ds), lit while on.
 *
 * Follows the iOS touch overlay (tie_app/ios/ios_app.m): the most used
 * controls sit on the MAIN page, the rest under tabs, and every button sends
 * one of the game's input actions through TieInputActions_DispatchController,
 * as a held gamepad button would. Throttle steps repeat while held, target
 * memories recall on a tap and store on a hold, and ejecting, ending the
 * mission and loading a checkpoint fire only after a hold.
 *
 * Layout (320 x 240): a status strip (page and frame rate), a 4 x 3 button
 * grid, and a tab bar.
 */
#include "tie_3ds/touch_panel_3ds.h"

#include "tie_3ds/settings_3ds.h"
#include "tie_runtime/input/actions.h"
#include "tie_runtime/runtime/quicksave.h"

#include <3ds.h>
#include <citro2d.h>
#include <stdio.h>
#include <string.h>

enum {
	TIE_3DS_PANEL_WIDTH = 320,
	TIE_3DS_PANEL_HEIGHT = 240,
	TIE_3DS_PANEL_COLUMNS = 4,
	TIE_3DS_PANEL_ROWS = 3,
	TIE_3DS_PANEL_BUTTONS = TIE_3DS_PANEL_COLUMNS * TIE_3DS_PANEL_ROWS,
	TIE_3DS_PANEL_STATUS_HEIGHT = 16,
	TIE_3DS_PANEL_TAB_HEIGHT = 40,
	TIE_3DS_PANEL_GRID_TOP = TIE_3DS_PANEL_STATUS_HEIGHT,
	TIE_3DS_PANEL_GRID_HEIGHT = TIE_3DS_PANEL_HEIGHT - TIE_3DS_PANEL_STATUS_HEIGHT - TIE_3DS_PANEL_TAB_HEIGHT,
	TIE_3DS_PANEL_TAB_TOP = TIE_3DS_PANEL_GRID_TOP + TIE_3DS_PANEL_GRID_HEIGHT,
	TIE_3DS_PANEL_GAP = 3,
	TIE_3DS_PANEL_REPEAT_DELAY_MS = 300,
	TIE_3DS_PANEL_REPEAT_INTERVAL_MS = 110,
	TIE_3DS_PANEL_HOLD_MS = 700,
	TIE_3DS_PANEL_TEXT_CAPACITY = 2048,
};

typedef enum TieN3dsButtonKind {
	TIE_3DS_BUTTON_EMPTY = 0,
	TIE_3DS_BUTTON_PRESS,  /* held while touched */
	TIE_3DS_BUTTON_REPEAT, /* tapped on touch, then repeatedly while held */
	TIE_3DS_BUTTON_HOLD,   /* tapped once after a hold (dangerous actions) */
	TIE_3DS_BUTTON_PRESET, /* tap: recall; hold: store (hold_action) */
	TIE_3DS_BUTTON_SAVE,   /* checkpoint save to slot */
	TIE_3DS_BUTTON_LOAD,   /* checkpoint load from slot, after a hold */
	TIE_3DS_BUTTON_SETTING, /* toggles the TieN3dsSetting in slot; lit while on */
} TieN3dsButtonKind;

typedef struct TieN3dsButton {
	const char* label;
	TieN3dsButtonKind kind;
	TieInputAction action;
	TieInputAction hold_action; /* PRESET: the store action */
	int slot;                   /* SAVE / LOAD: checkpoint; SETTING: TieN3dsSetting */
} TieN3dsButton;

typedef struct TieN3dsPage {
	const char* tab;
	TieN3dsButton buttons[TIE_3DS_PANEL_BUTTONS];
} TieN3dsPage;

#define PRESS(text, act) { text, TIE_3DS_BUTTON_PRESS, act, TIE_INPUT_ACTION_NONE, 0 }
#define REPEAT(text, act) { text, TIE_3DS_BUTTON_REPEAT, act, TIE_INPUT_ACTION_NONE, 0 }
#define HOLD(text, act) { text, TIE_3DS_BUTTON_HOLD, act, TIE_INPUT_ACTION_NONE, 0 }
#define PRESET(text, recall, store) { text, TIE_3DS_BUTTON_PRESET, recall, store, 0 }
#define SAVE(text, n) { text, TIE_3DS_BUTTON_SAVE, TIE_INPUT_ACTION_NONE, TIE_INPUT_ACTION_NONE, n }
#define LOAD(text, n) { text, TIE_3DS_BUTTON_LOAD, TIE_INPUT_ACTION_NONE, TIE_INPUT_ACTION_NONE, n }
#define SETTING(text, n) { text, TIE_3DS_BUTTON_SETTING, TIE_INPUT_ACTION_NONE, TIE_INPUT_ACTION_NONE, n }

static const TieN3dsPage k_pages[] = {
	{ "MAIN",
	  {
		  PRESS("TGT >", TIE_INPUT_ACTION_TARGET_NEXT),
		  PRESS("TGT <", TIE_INPUT_ACTION_TARGET_PREV),
		  PRESS("NEAREST", TIE_INPUT_ACTION_TARGET_NEAREST_FIGHTER_OR_MINE),
		  PRESS("ATTACKER", TIE_INPUT_ACTION_TARGET_MY_ATTACKER),
		  PRESS("WEAPON", TIE_INPUT_ACTION_CYCLE_WEAPON_GROUP),
		  PRESS("LINK", TIE_INPUT_ACTION_CYCLE_WEAPON_FIRING_MODE),
		  PRESS("MATCH", TIE_INPUT_ACTION_MATCH_SPEED),
		  REPEAT("THR +", TIE_INPUT_ACTION_THROTTLE_UP),
		  PRESS("LSR>SHD", TIE_INPUT_ACTION_XFER_CANNON_TO_SHIELDS),
		  PRESS("SHD>LSR", TIE_INPUT_ACTION_XFER_SHIELDS_TO_CANNON),
		  PRESS("SHIELDS", TIE_INPUT_ACTION_CYCLE_SHIELD_MODE),
		  REPEAT("THR -", TIE_INPUT_ACTION_THROTTLE_DOWN),
	  } },
	{ "PWR",
	  {
		  PRESS("LSR RATE", TIE_INPUT_ACTION_CYCLE_CANNON_RECHARGE_RATE),
		  PRESS("SHD RATE", TIE_INPUT_ACTION_CYCLE_SHIELD_RECHARGE_RATE),
		  PRESS("BEAM RATE", TIE_INPUT_ACTION_CYCLE_BEAM_RECHARGE_RATE),
		  PRESS("BEAM", TIE_INPUT_ACTION_TOGGLE_BEAM),
		  PRESS("LSR>SHD", TIE_INPUT_ACTION_XFER_CANNON_TO_SHIELDS),
		  PRESS("SHD>LSR", TIE_INPUT_ACTION_XFER_SHIELDS_TO_CANNON),
		  PRESS("SHIELDS", TIE_INPUT_ACTION_CYCLE_SHIELD_MODE),
		  PRESS("SLAM", TIE_INPUT_ACTION_TOGGLE_SLAM),
		  PRESS("THR 0", TIE_INPUT_ACTION_THROTTLE_ZERO),
		  PRESS("THR 1/3", TIE_INPUT_ACTION_THROTTLE_ONE_THIRD),
		  PRESS("THR 2/3", TIE_INPUT_ACTION_THROTTLE_TWO_THIRDS),
		  PRESS("THR MAX", TIE_INPUT_ACTION_THROTTLE_FULL),
	  } },
	{ "TGT",
	  {
		  PRESS("CHAIN", TIE_INPUT_ACTION_TARGET_ATTACKER_CHAIN),
		  PRESS("NEWEST", TIE_INPUT_ACTION_TARGET_NEWEST_CRAFT),
		  PRESS("COMP >", TIE_INPUT_ACTION_TARGET_COMPONENT_NEXT),
		  PRESS("COMP <", TIE_INPUT_ACTION_TARGET_COMPONENT_PREV),
		  PRESS("VIEW TGT", TIE_INPUT_ACTION_TOGGLE_THREAT_DISPLAY),
		  PRESS("CLEAR", TIE_INPUT_ACTION_TARGET_CLEAR),
		  PRESS("AUTO", TIE_INPUT_ACTION_AUTO_TARGET),
		  PRESS("TRACK", TIE_INPUT_ACTION_TOGGLE_COMPONENT_TRACKING),
		  PRESET("T1", TIE_INPUT_ACTION_TARGET_PRESET_RECALL_1, TIE_INPUT_ACTION_TARGET_PRESET_STORE_1),
		  PRESET("T2", TIE_INPUT_ACTION_TARGET_PRESET_RECALL_2, TIE_INPUT_ACTION_TARGET_PRESET_STORE_2),
		  PRESET("T3", TIE_INPUT_ACTION_TARGET_PRESET_RECALL_3, TIE_INPUT_ACTION_TARGET_PRESET_STORE_3),
	  } },
	{ "VIEW",
	  {
		  PRESS("L FWD", TIE_INPUT_ACTION_VIEW_LEFT_FORWARD),
		  PRESS("UP", TIE_INPUT_ACTION_VIEW_STRAIGHT_UP),
		  PRESS("R FWD", TIE_INPUT_ACTION_VIEW_RIGHT_FORWARD),
		  PRESS("COCKPIT", TIE_INPUT_ACTION_VIEW_TOGGLE_COCKPIT),
		  PRESS("LEFT", TIE_INPUT_ACTION_VIEW_LEFT_WING),
		  PRESS("FORWARD", TIE_INPUT_ACTION_VIEW_FORWARD),
		  PRESS("RIGHT", TIE_INPUT_ACTION_VIEW_RIGHT_WING),
		  PRESS("EXT CAM", TIE_INPUT_ACTION_VIEW_TOGGLE_EXTERNAL_CAMERA),
		  PRESS("L SHLDR", TIE_INPUT_ACTION_VIEW_LEFT_SHOULDER),
		  PRESS("REAR", TIE_INPUT_ACTION_VIEW_REAR),
		  PRESS("R SHLDR", TIE_INPUT_ACTION_VIEW_RIGHT_SHOULDER),
		  PRESS("MSL CAM", TIE_INPUT_ACTION_CYCLE_WARHEAD_VIEW),
	  } },
	{ "INFO",
	  {
		  PRESS("MAP", TIE_INPUT_ACTION_INFO_MAP),
		  PRESS("GOALS", TIE_INPUT_ACTION_INFO_GOALS),
		  PRESS("MSGS", TIE_INPUT_ACTION_INFO_MESSAGES),
		  PRESS("DAMAGE", TIE_INPUT_ACTION_INFO_DAMAGE),
		  PRESS("WINGMEN", TIE_INPUT_ACTION_INFO_WINGMAN_COMMANDS),
		  PRESS("HELP", TIE_INPUT_ACTION_INFO_HELP),
		  PRESS("< ITEM", TIE_INPUT_ACTION_INFO_PREVIOUS_ITEM),
		  PRESS("ITEM >", TIE_INPUT_ACTION_INFO_NEXT_ITEM),
		  PRESS("CAM CTRL", TIE_INPUT_ACTION_VIEW_TOGGLE_EXTERNAL_CAMERA_CONTROL),
		  PRESS("HI ANGLE", TIE_INPUT_ACTION_VIEW_TOGGLE_HIGH_ANGLE),
		  PRESS("THREAT", TIE_INPUT_ACTION_TOGGLE_THREAT_DISPLAY),
		  PRESS("OK", TIE_INPUT_ACTION_CONFIRM),
	  } },
	{ "CMD",
	  {
		  PRESS("ATTACK", TIE_INPUT_ACTION_COMM_ASSIGN_TARGET),
		  PRESS("COVER", TIE_INPUT_ACTION_COMM_COVER_ME),
		  PRESS("EVADE", TIE_INPUT_ACTION_COMM_EVADE),
		  PRESS("IGNORE", TIE_INPUT_ACTION_COMM_IGNORE_TARGET),
		  PRESS("WAIT", TIE_INPUT_ACTION_COMM_STOP_AND_WAIT),
		  PRESS("GO ON", TIE_INPUT_ACTION_COMM_CONTINUE_MISSION),
		  PRESS("HOME", TIE_INPUT_ACTION_COMM_HEAD_HOME),
		  PRESS("REPORT", TIE_INPUT_ACTION_COMM_REPORT_ORDERS),
		  PRESS("RESUPPLY", TIE_INPUT_ACTION_COMM_REQUEST_RESUPPLY),
		  PRESS("REINFORCE", TIE_INPUT_ACTION_COMM_REINFORCEMENTS),
	  } },
	{ "MSN",
	  {
		  PRESS("PAUSE", TIE_INPUT_ACTION_PAUSE),
		  PRESS("TIME x", TIE_INPUT_ACTION_CYCLE_TIME_ACCELERATION),
		  PRESS("HYPER", TIE_INPUT_ACTION_HYPERSPACE),
		  PRESS("REC", TIE_INPUT_ACTION_RECORDER_TOGGLE),
		  PRESS("OK", TIE_INPUT_ACTION_CONFIRM),
		  PRESS("ESC", TIE_INPUT_ACTION_ESCAPE),
		  HOLD("EJECT", TIE_INPUT_ACTION_EJECT),
		  HOLD("END", TIE_INPUT_ACTION_END_MISSION),
	  } },
	{ "SAVE",
	  {
		  SAVE("SAVE 1", 1),
		  SAVE("SAVE 2", 2),
		  SAVE("SAVE 3", 3),
		  { 0 },
		  LOAD("LOAD 1", 1),
		  LOAD("LOAD 2", 2),
		  LOAD("LOAD 3", 3),
	  } },
	{ "SYS",
	  {
		  SETTING("INV PITCH", TIE_3DS_SETTING_INVERT_PITCH),
		  SETTING("INV YAW", TIE_3DS_SETTING_INVERT_YAW),
		  SETTING("INV ROLL", TIE_3DS_SETTING_INVERT_ROLL),
		  SETTING("GYRO", TIE_3DS_SETTING_GYRO),
	  } },
};

enum { TIE_3DS_PANEL_PAGES = (int)(sizeof k_pages / sizeof k_pages[0]) };

typedef enum TieN3dsTouchTarget {
	TIE_3DS_TOUCH_NONE,
	TIE_3DS_TOUCH_BUTTON,
	TIE_3DS_TOUCH_TAB,
} TieN3dsTouchTarget;

static struct {
	bool active;
	int page;
	/* The touch in progress. */
	TieN3dsTouchTarget touch;
	int touch_index;
	u64 touch_start_ms;
	u64 next_repeat_ms;
	bool held_fired; /* a HOLD / PRESET / LOAD fired its hold */
	bool action_down;
	/* Labels, parsed once with the system font. */
	bool text_ready;
	C2D_TextBuf text_buffer;
	C2D_Text tab_text[TIE_3DS_PANEL_PAGES];
	C2D_Text button_text[TIE_3DS_PANEL_PAGES][TIE_3DS_PANEL_BUTTONS];
	/* The status strip's frame rate and tick time, reparsed when they change. */
	float fps;
	float tick_ms;
	bool fps_changed;
	C2D_TextBuf status_buffer;
	C2D_Text status_text;
} s_panel;

static void TieN3dsTouchPanel_Tap(TieInputAction action) {
	if (action == TIE_INPUT_ACTION_NONE)
		return;
	TieInputActions_DispatchController(action, true);
	TieInputActions_DispatchController(action, false);
}

static const TieN3dsButton* TieN3dsTouchPanel_TouchedButton(void) {
	if (s_panel.touch != TIE_3DS_TOUCH_BUTTON)
		return NULL;
	return &k_pages[s_panel.page].buttons[s_panel.touch_index];
}

static void TieN3dsTouchPanel_EndTouch(void) {
	const TieN3dsButton* button = TieN3dsTouchPanel_TouchedButton();
	if (button && s_panel.action_down)
		TieInputActions_DispatchController(button->action, false);
	s_panel.touch = TIE_3DS_TOUCH_NONE;
	s_panel.action_down = false;
}

void TieN3dsTouchPanel_SetActive(bool active) {
	if (active == s_panel.active)
		return;
	if (!active)
		TieN3dsTouchPanel_EndTouch();
	s_panel.active = active;
}

bool TieN3dsTouchPanel_Active(void) { return s_panel.active; }

static void TieN3dsTouchPanel_ButtonRect(int index, float* x, float* y, float* width, float* height) {
	const float cell_width = (float)TIE_3DS_PANEL_WIDTH / TIE_3DS_PANEL_COLUMNS;
	const float cell_height = (float)TIE_3DS_PANEL_GRID_HEIGHT / TIE_3DS_PANEL_ROWS;
	*x = (float)(index % TIE_3DS_PANEL_COLUMNS) * cell_width + TIE_3DS_PANEL_GAP;
	*y = (float)TIE_3DS_PANEL_GRID_TOP + (float)(index / TIE_3DS_PANEL_COLUMNS) * cell_height + TIE_3DS_PANEL_GAP;
	*width = cell_width - 2 * TIE_3DS_PANEL_GAP;
	*height = cell_height - 2 * TIE_3DS_PANEL_GAP;
}

static void TieN3dsTouchPanel_TabRect(int index, float* x, float* y, float* width, float* height) {
	const float tab_width = (float)TIE_3DS_PANEL_WIDTH / TIE_3DS_PANEL_PAGES;
	*x = (float)index * tab_width + 1.0f;
	*y = (float)TIE_3DS_PANEL_TAB_TOP + 2.0f;
	*width = tab_width - 2.0f;
	*height = (float)TIE_3DS_PANEL_TAB_HEIGHT - 3.0f;
}

static void TieN3dsTouchPanel_BeginTouch(int px, int py, u64 now_ms) {
	if (py < TIE_3DS_PANEL_GRID_TOP)
		return;
	if (py >= TIE_3DS_PANEL_TAB_TOP) {
		const int tab = px * TIE_3DS_PANEL_PAGES / TIE_3DS_PANEL_WIDTH;
		if (tab >= 0 && tab < TIE_3DS_PANEL_PAGES) {
			s_panel.touch = TIE_3DS_TOUCH_TAB;
			s_panel.page = tab;
		}
		return;
	}
	const int column = px * TIE_3DS_PANEL_COLUMNS / TIE_3DS_PANEL_WIDTH;
	const int row = (py - TIE_3DS_PANEL_GRID_TOP) * TIE_3DS_PANEL_ROWS / TIE_3DS_PANEL_GRID_HEIGHT;
	const int index = row * TIE_3DS_PANEL_COLUMNS + column;
	if (column < 0 || column >= TIE_3DS_PANEL_COLUMNS || row < 0 || row >= TIE_3DS_PANEL_ROWS)
		return;
	const TieN3dsButton* button = &k_pages[s_panel.page].buttons[index];
	if (button->kind == TIE_3DS_BUTTON_EMPTY)
		return;
	s_panel.touch = TIE_3DS_TOUCH_BUTTON;
	s_panel.touch_index = index;
	s_panel.touch_start_ms = now_ms;
	s_panel.held_fired = false;
	switch (button->kind) {
		case TIE_3DS_BUTTON_PRESS:
			TieInputActions_DispatchController(button->action, true);
			s_panel.action_down = true;
			break;
		case TIE_3DS_BUTTON_REPEAT:
			TieN3dsTouchPanel_Tap(button->action);
			s_panel.next_repeat_ms = now_ms + TIE_3DS_PANEL_REPEAT_DELAY_MS;
			break;
		case TIE_3DS_BUTTON_SAVE:
			TieQuickSave_RequestSave(button->slot);
			break;
		case TIE_3DS_BUTTON_SETTING:
			TieN3dsSettings_Toggle((TieN3dsSetting)button->slot);
			break;
		default:
			break;
	}
}

static void TieN3dsTouchPanel_ContinueTouch(u64 now_ms) {
	const TieN3dsButton* button = TieN3dsTouchPanel_TouchedButton();
	if (!button)
		return;
	const bool held_long = now_ms - s_panel.touch_start_ms >= TIE_3DS_PANEL_HOLD_MS;
	switch (button->kind) {
		case TIE_3DS_BUTTON_REPEAT:
			if (now_ms >= s_panel.next_repeat_ms) {
				TieN3dsTouchPanel_Tap(button->action);
				s_panel.next_repeat_ms = now_ms + TIE_3DS_PANEL_REPEAT_INTERVAL_MS;
			}
			break;
		case TIE_3DS_BUTTON_HOLD:
			if (held_long && !s_panel.held_fired) {
				TieN3dsTouchPanel_Tap(button->action);
				s_panel.held_fired = true;
			}
			break;
		case TIE_3DS_BUTTON_PRESET:
			if (held_long && !s_panel.held_fired) {
				TieN3dsTouchPanel_Tap(button->hold_action);
				s_panel.held_fired = true;
			}
			break;
		case TIE_3DS_BUTTON_LOAD:
			if (held_long && !s_panel.held_fired && TieQuickSave_HasCheckpoint(button->slot)) {
				TieQuickSave_RequestLoad(button->slot);
				s_panel.held_fired = true;
			}
			break;
		default:
			break;
	}
}

static void TieN3dsTouchPanel_FinishTouch(void) {
	const TieN3dsButton* button = TieN3dsTouchPanel_TouchedButton();
	if (button && button->kind == TIE_3DS_BUTTON_PRESET && !s_panel.held_fired)
		TieN3dsTouchPanel_Tap(button->action);
	TieN3dsTouchPanel_EndTouch();
}

void TieN3dsTouchPanel_Update(void) {
	if (!s_panel.active)
		return;
	/* SDL's event pump has already scanned the HID state this frame. */
	const u32 held = hidKeysHeld();
	const u64 now_ms = osGetTime();
	if (!(held & KEY_TOUCH)) {
		if (s_panel.touch != TIE_3DS_TOUCH_NONE)
			TieN3dsTouchPanel_FinishTouch();
		return;
	}
	if (s_panel.touch == TIE_3DS_TOUCH_NONE && (hidKeysDown() & KEY_TOUCH)) {
		touchPosition touch;
		hidTouchRead(&touch);
		TieN3dsTouchPanel_BeginTouch(touch.px, touch.py, now_ms);
		return;
	}
	TieN3dsTouchPanel_ContinueTouch(now_ms);
}

/* ---- Drawing ----------------------------------------------------------- */

#define TIE_3DS_COLOR_BACKGROUND C2D_Color32(0x0A, 0x0E, 0x14, 0xFF)
#define TIE_3DS_COLOR_BUTTON C2D_Color32(0x2A, 0x34, 0x44, 0xFF)
#define TIE_3DS_COLOR_BUTTON_PRESSED C2D_Color32(0x5C, 0x7A, 0xA6, 0xFF)
#define TIE_3DS_COLOR_BUTTON_DANGER C2D_Color32(0x5A, 0x22, 0x22, 0xFF)
#define TIE_3DS_COLOR_BUTTON_DISABLED C2D_Color32(0x1A, 0x1E, 0x24, 0xFF)
#define TIE_3DS_COLOR_BUTTON_ON C2D_Color32(0x2E, 0x6A, 0x4A, 0xFF)
#define TIE_3DS_COLOR_HOLD_PROGRESS C2D_Color32(0xC8, 0x3C, 0x3C, 0xFF)
#define TIE_3DS_COLOR_TAB C2D_Color32(0x16, 0x1C, 0x26, 0xFF)
#define TIE_3DS_COLOR_TAB_SELECTED C2D_Color32(0x3A, 0x4E, 0x6E, 0xFF)
#define TIE_3DS_COLOR_LABEL C2D_Color32(0xE0, 0xE6, 0xEE, 0xFF)
#define TIE_3DS_COLOR_LABEL_DIM C2D_Color32(0x70, 0x76, 0x80, 0xFF)

void TieN3dsTouchPanel_SetStats(float fps, float tick_ms) {
	s_panel.fps = fps;
	s_panel.tick_ms = tick_ms;
	s_panel.fps_changed = true;
}

static void TieN3dsTouchPanel_PrepareText(void) {
	if (s_panel.text_ready && !s_panel.fps_changed)
		return;
	if (s_panel.text_ready) {
		char status[48];
		snprintf(status, sizeof status, "tick %.1f ms   %.1f fps", (double)s_panel.tick_ms, (double)s_panel.fps);
		C2D_TextBufClear(s_panel.status_buffer);
		C2D_TextParse(&s_panel.status_text, s_panel.status_buffer, status);
		C2D_TextOptimize(&s_panel.status_text);
		s_panel.fps_changed = false;
		return;
	}
	s_panel.status_buffer = C2D_TextBufNew(48);
	C2D_TextParse(&s_panel.status_text, s_panel.status_buffer, "");
	s_panel.fps_changed = s_panel.fps > 0.0f;
	s_panel.text_buffer = C2D_TextBufNew(TIE_3DS_PANEL_TEXT_CAPACITY);
	for (int page = 0; page < TIE_3DS_PANEL_PAGES; ++page) {
		C2D_TextParse(&s_panel.tab_text[page], s_panel.text_buffer, k_pages[page].tab);
		C2D_TextOptimize(&s_panel.tab_text[page]);
		for (int i = 0; i < TIE_3DS_PANEL_BUTTONS; ++i) {
			const char* label = k_pages[page].buttons[i].label;
			C2D_TextParse(&s_panel.button_text[page][i], s_panel.text_buffer, label ? label : "");
			C2D_TextOptimize(&s_panel.button_text[page][i]);
		}
	}
	s_panel.text_ready = true;
	if (s_panel.fps_changed)
		TieN3dsTouchPanel_PrepareText();
}

static bool TieN3dsTouchPanel_ButtonDisabled(const TieN3dsButton* button) {
	return button->kind == TIE_3DS_BUTTON_LOAD && !TieQuickSave_HasCheckpoint(button->slot);
}

static bool TieN3dsTouchPanel_ButtonDangerous(const TieN3dsButton* button) {
	return button->kind == TIE_3DS_BUTTON_HOLD || button->kind == TIE_3DS_BUTTON_LOAD;
}

void TieN3dsTouchPanel_Draw(void) {
	TieN3dsTouchPanel_PrepareText();
	C2D_DrawRectSolid(0.0f, 0.0f, 0.0f, TIE_3DS_PANEL_WIDTH, TIE_3DS_PANEL_HEIGHT, TIE_3DS_COLOR_BACKGROUND);
	C2D_DrawText(&s_panel.tab_text[s_panel.page], C2D_WithColor, 6.0f, 1.0f, 0.3f, 0.42f, 0.42f,
				 TIE_3DS_COLOR_LABEL_DIM);
	C2D_DrawText(&s_panel.status_text, C2D_WithColor | C2D_AlignRight, TIE_3DS_PANEL_WIDTH - 6.0f, 1.0f, 0.3f,
				 0.42f, 0.42f, TIE_3DS_COLOR_LABEL_DIM);

	const u64 now_ms = osGetTime();
	const TieN3dsPage* page = &k_pages[s_panel.page];
	for (int i = 0; i < TIE_3DS_PANEL_BUTTONS; ++i) {
		const TieN3dsButton* button = &page->buttons[i];
		if (button->kind == TIE_3DS_BUTTON_EMPTY)
			continue;
		float x, y, width, height;
		TieN3dsTouchPanel_ButtonRect(i, &x, &y, &width, &height);
		const bool pressed = s_panel.touch == TIE_3DS_TOUCH_BUTTON && s_panel.touch_index == i;
		const bool disabled = TieN3dsTouchPanel_ButtonDisabled(button);
		u32 color = TIE_3DS_COLOR_BUTTON;
		if (disabled)
			color = TIE_3DS_COLOR_BUTTON_DISABLED;
		else if (pressed)
			color = TIE_3DS_COLOR_BUTTON_PRESSED;
		else if (TieN3dsTouchPanel_ButtonDangerous(button))
			color = TIE_3DS_COLOR_BUTTON_DANGER;
		else if (button->kind == TIE_3DS_BUTTON_SETTING && TieN3dsSettings_Get((TieN3dsSetting)button->slot))
			color = TIE_3DS_COLOR_BUTTON_ON;
		C2D_DrawRectSolid(x, y, 0.1f, width, height, color);
		/* A hold-to-confirm button fills as it is held. */
		if (pressed && !disabled && !s_panel.held_fired &&
			(TieN3dsTouchPanel_ButtonDangerous(button) || button->kind == TIE_3DS_BUTTON_PRESET)) {
			float progress = (float)(now_ms - s_panel.touch_start_ms) / TIE_3DS_PANEL_HOLD_MS;
			if (progress > 1.0f)
				progress = 1.0f;
			C2D_DrawRectSolid(x, y + height - 6.0f, 0.2f, width * progress, 6.0f, TIE_3DS_COLOR_HOLD_PROGRESS);
		}
		C2D_DrawText(&s_panel.button_text[s_panel.page][i], C2D_WithColor | C2D_AlignCenter, x + width * 0.5f,
					 y + height * 0.5f - 9.0f, 0.3f, 0.55f, 0.55f,
					 disabled ? TIE_3DS_COLOR_LABEL_DIM : TIE_3DS_COLOR_LABEL);
	}

	for (int tab = 0; tab < TIE_3DS_PANEL_PAGES; ++tab) {
		float x, y, width, height;
		TieN3dsTouchPanel_TabRect(tab, &x, &y, &width, &height);
		C2D_DrawRectSolid(x, y, 0.1f, width, height,
						  tab == s_panel.page ? TIE_3DS_COLOR_TAB_SELECTED : TIE_3DS_COLOR_TAB);
		C2D_DrawText(&s_panel.tab_text[tab], C2D_WithColor | C2D_AlignCenter, x + width * 0.5f,
					 y + height * 0.5f - 7.0f, 0.3f, 0.45f, 0.45f, TIE_3DS_COLOR_LABEL);
	}
}

void TieN3dsTouchPanel_Shutdown(void) {
	TieN3dsTouchPanel_SetActive(false);
	if (s_panel.text_ready) {
		C2D_TextBufDelete(s_panel.text_buffer);
		C2D_TextBufDelete(s_panel.status_buffer);
	}
	s_panel.text_ready = false;
}
