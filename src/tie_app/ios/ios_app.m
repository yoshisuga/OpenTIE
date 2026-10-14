/* iOS integration: game folders in Documents and the on-screen controls.
 *
 * The overlay is a UIView over SDL's view. UIKit delivers its touches while
 * Aeron pumps SDL events on the main thread, so the handlers call into the
 * runtime directly. The flight stick drives an SDL virtual gamepad, which
 * the controller mapping picks up with the shipped gamepad defaults; the
 * buttons dispatch input actions, so they keep working if the gamepad
 * bindings are changed. Outside flight only ESC and the keyboard button
 * show, and every other touch reaches SDL as a mouse click. */

#include "tie_app/ios/ios_app.h"

#include "tie_app/application.h"
#include "tie_app/config/app_config.h"
#include "tie_app/settings/settings.h"
#include "tie_app/setup/installation.h"
#include "tie_runtime/input/actions.h"
#include "tie_runtime/input/controller_mapping.h"
#include "tie_runtime/input/input.h"
#include "tie_runtime/presentation/presentation.h"
#include "tie_runtime/runtime/flight_requests.h"
#include "tie_runtime/runtime/flight_screen.h"
#include "tie_runtime/snapshot/snapshot.h"
#include "tie_runtime/timing/user_timing.h"

#include <SDL3/SDL.h>

#import <UIKit/UIKit.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* ---------------- Game folders ---------------- */

static char ios_tie95_path[TIE_GAME_DATA_PATH_MAX];
static char ios_tie98_path[TIE_GAME_DATA_PATH_MAX];

static NSString* TieIos_DocumentsDirectory(void) {
	return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

void TieIos_FindInstallations(TieLaunchOptions* launch) {
	NSString* documents = TieIos_DocumentsDirectory();
	if (!documents || (launch->tie95_data && launch->tie98_data))
		return;
	NSFileManager* files = [NSFileManager defaultManager];
	NSArray<NSString*>* names = [files contentsOfDirectoryAtPath:documents error:nil];
	/* An empty Documents gets folders to copy each edition into. */
	if (names.count == 0) {
		for (NSString* name in @[ @"TIE95", @"TIE98" ])
			[files createDirectoryAtPath:[documents stringByAppendingPathComponent:name]
				withIntermediateDirectories:YES
								 attributes:nil
									  error:nil];
		return;
	}
	for (NSString* name in [names sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
		NSString* path = [documents stringByAppendingPathComponent:name];
		BOOL directory = NO;
		if (![files fileExistsAtPath:path isDirectory:&directory] || !directory)
			continue;
		TieGameVersion version;
		char error[512];
		if (!TieInstallation_Classify(path.fileSystemRepresentation, &version, error, sizeof error)) {
			SDL_Log("[tie-ios] Documents/%s is not used: %s", name.UTF8String, error);
			continue;
		}
		char* destination = version == TIE_GAME_VERSION_TIE98 ? ios_tie98_path : ios_tie95_path;
		const char** option = version == TIE_GAME_VERSION_TIE98 ? &launch->tie98_data : &launch->tie95_data;
		if (*option || destination[0])
			continue;
		snprintf(destination, TIE_GAME_DATA_PATH_MAX, "%s", path.fileSystemRepresentation);
		*option = destination;
		SDL_Log("[tie-ios] %s installation: %s", version == TIE_GAME_VERSION_TIE98 ? "TIE98" : "TIE95",
				destination);
	}
}

void TieIos_RebaseDocumentsPath(char* path, size_t capacity) {
	static const char marker[] = "/Documents/";
	char* tail = path ? strstr(path, marker) : NULL;
	NSString* documents = TieIos_DocumentsDirectory();
	if (!tail || !documents)
		return;
	char rebased[TIE_GAME_DATA_PATH_MAX];
	const int length =
		snprintf(rebased, sizeof rebased, "%s/%s", documents.fileSystemRepresentation, tail + strlen(marker));
	if (length > 0 && (size_t)length < capacity && (size_t)length < sizeof rebased)
		memcpy(path, rebased, (size_t)length + 1);
}

/* ---------------- Virtual gamepad ---------------- */

static SDL_Joystick* ios_gamepad;

/* Set when a game controller is used, cleared by the next touch; the touch
 * controls stand aside while it is set. Simply being connected is not
 * enough, since a paired controller may be put away. */
static bool ios_controller_in_use;

static bool SDLCALL TieIos_WatchEvent(void* userdata, SDL_Event* event) {
	(void)userdata;
	switch (event->type) {
		case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
			ios_controller_in_use |= !SDL_IsJoystickVirtual(event->gbutton.which);
			break;
		case SDL_EVENT_GAMEPAD_AXIS_MOTION:
			if (abs(event->gaxis.value) > SDL_JOYSTICK_AXIS_MAX / 2)
				ios_controller_in_use |= !SDL_IsJoystickVirtual(event->gaxis.which);
			break;
		case SDL_EVENT_GAMEPAD_REMOVED:
		case SDL_EVENT_FINGER_DOWN:
			ios_controller_in_use = false;
			break;
		default:
			break;
	}
	return true;
}

static void TieIos_AttachGamepad(void) {
	if (ios_gamepad)
		return;
	SDL_VirtualJoystickDesc desc;
	SDL_INIT_INTERFACE(&desc);
	desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
	desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
	desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
	desc.axis_mask = (1u << SDL_GAMEPAD_AXIS_LEFTX) | (1u << SDL_GAMEPAD_AXIS_LEFTY) |
					 (1u << SDL_GAMEPAD_AXIS_RIGHTX) | (1u << SDL_GAMEPAD_AXIS_RIGHTY);
	desc.button_mask = (1u << SDL_GAMEPAD_BUTTON_SOUTH) | (1u << SDL_GAMEPAD_BUTTON_EAST);
	desc.name = "OpenTIE Touch Controls";
	const SDL_JoystickID id = SDL_AttachVirtualJoystick(&desc);
	if (!id) {
		SDL_Log("[tie-ios] virtual gamepad unavailable: %s", SDL_GetError());
		return;
	}
	ios_gamepad = SDL_OpenJoystick(id);
	if (!ios_gamepad)
		SDL_DetachVirtualJoystick(id);
}

static void TieIos_DetachGamepad(void) {
	if (!ios_gamepad)
		return;
	const SDL_JoystickID id = SDL_GetJoystickID(ios_gamepad);
	SDL_CloseJoystick(ios_gamepad);
	SDL_DetachVirtualJoystick(id);
	ios_gamepad = NULL;
}

static void TieIos_SetStick(float x, float y) {
	if (!ios_gamepad)
		return;
	SDL_SetJoystickVirtualAxis(ios_gamepad, SDL_GAMEPAD_AXIS_LEFTX, (Sint16)lroundf(x * SDL_JOYSTICK_AXIS_MAX));
	SDL_SetJoystickVirtualAxis(ios_gamepad, SDL_GAMEPAD_AXIS_LEFTY, (Sint16)lroundf(y * SDL_JOYSTICK_AXIS_MAX));
}

/* The throttle slider drives the right stick's Y axis, 0..1. The shipped
 * gamepad defaults bind the triggers to FIRE and ROLL but leave this axis
 * free, so the throttle cannot press either. */
static void TieIos_SetThrottleAxis(float value) {
	if (!ios_gamepad)
		return;
	SDL_SetJoystickVirtualAxis(ios_gamepad, SDL_GAMEPAD_AXIS_RIGHTY, (Sint16)lroundf(value * 65535.0f - 32768.0f));
}

/* The touch gamepad's saved profile takes its throttle from the right
 * stick's Y axis; the shipped gamepad defaults leave throttle unmapped. */
static void TieIos_MapTouchThrottle(void) {
	TieAppConfigState* config = TieAppConfig_Current();
	if (!ios_gamepad || !config)
		return;
	char guid[33];
	SDL_GUIDToString(SDL_GetJoystickGUID(ios_gamepad), guid, sizeof guid);
	const int index = TieControllerMapping_FindModel(&config->requested.controller, guid);
	if (index < 0)
		return;
	const TieInputAxisBinding throttle = { .source = AERON_GAMEPAD_AXIS_RIGHTY };
	const TieInputAxisBinding* current =
		&config->requested.controller.models[index].profile.mapping.axes[TIE_INPUT_AXIS_THROTTLE];
	if (current->source == throttle.source)
		return;
	TieControllerOptions options = config->requested.controller;
	options.models[index].profile.mapping.axes[TIE_INPUT_AXIS_THROTTLE] = throttle;
	char error[512];
	if (TieAppConfig_SetController(config, &options, error, sizeof error))
		TieControllerMapping_SetOptions(&config->requested.controller);
	else
		SDL_Log("[tie-ios] could not map the touch throttle: %s", error);
}

/* ---------------- Buttons ---------------- */

typedef enum TieIosButtonKind {
	TIE_IOS_BUTTON_ACTION,   /* press and release one input action */
	TIE_IOS_BUTTON_REPEAT,   /* an action pressed again while held */
	TIE_IOS_BUTTON_TAP_HOLD, /* one action on a tap, another on a hold */
	TIE_IOS_BUTTON_KEYBOARD, /* shows or hides the screen keyboard */
	TIE_IOS_BUTTON_TOGGLE,   /* opens or closes a group of buttons */
	TIE_IOS_BUTTON_ENTER,    /* the Enter key */
} TieIosButtonKind;

typedef enum TieIosButtonPlace {
	TIE_IOS_PLACE_ALWAYS, /* menus and flight */
	TIE_IOS_PLACE_FLIGHT, /* the cockpit only */
	TIE_IOS_PLACE_MENUS,  /* everywhere but the cockpit */
} TieIosButtonPlace;

static const CFTimeInterval TIE_IOS_HOLD_SECONDS = 0.5;

@interface TieTouchButton : UIView
@property(nonatomic) TieInputAction action;
@property(nonatomic) TieInputAction holdAction;
@property(nonatomic) TieIosButtonKind kind;
@property(nonatomic) TieIosButtonPlace place;
@property(nonatomic) BOOL held;
@property(nonatomic) BOOL holdFired;
@property(nonatomic) CFTimeInterval pressTime;
@property(nonatomic) CFTimeInterval nextRepeat;
@property(nonatomic, strong) UILabel* label;
@property(nonatomic, copy) void (^toggle)(void);
@end

@implementation TieTouchButton

- (instancetype)initWithTitle:(NSString*)title
					   action:(TieInputAction)action
						 kind:(TieIosButtonKind)kind
						place:(TieIosButtonPlace)place {
	if ((self = [super initWithFrame:CGRectZero])) {
		_action = action;
		_kind = kind;
		_place = place;
		self.multipleTouchEnabled = NO;
		self.layer.borderWidth = 1.5;
		self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
		_label = [[UILabel alloc] initWithFrame:CGRectZero];
		_label.text = title;
		_label.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
		_label.textAlignment = NSTextAlignmentCenter;
		_label.adjustsFontSizeToFitWidth = YES;
		_label.minimumScaleFactor = 0.4;
		_label.numberOfLines = 2;
		[self addSubview:_label];
		[self setHeld:NO];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5;
	_label.frame = CGRectInset(self.bounds, 4, 2);
	_label.font = [UIFont boldSystemFontOfSize:MAX(9.0, MIN(self.bounds.size.height * 0.28, 20.0))];
}

- (void)setHeld:(BOOL)held {
	_held = held;
	self.backgroundColor = [UIColor colorWithWhite:held ? 0.85 : 0.15 alpha:held ? 0.45 : 0.3];
}

/* A group toggle shows whether its group is open. */
- (void)setOpen:(BOOL)open {
	self.layer.borderColor = open ? [UIColor colorWithRed:1.0 green:0.8 blue:0.3 alpha:0.9].CGColor
								  : [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
}

static void TieIos_ToggleKeyboard(void) {
	SDL_Window* window = SDL_GetKeyboardFocus();
	if (!window) {
		int count = 0;
		SDL_Window** windows = SDL_GetWindows(&count);
		window = windows && count > 0 ? windows[0] : NULL;
		SDL_free(windows);
	}
	if (!window)
		return;
	if (SDL_TextInputActive(window)) {
		SDL_StopTextInput(window);
		return;
	}
	/* Pilot names and cheats: no autocorrect or capitals, so each key
	 * reaches the game as typed. */
	const SDL_PropertiesID props = SDL_CreateProperties();
	SDL_SetNumberProperty(props, SDL_PROP_TEXTINPUT_CAPITALIZATION_NUMBER, SDL_CAPITALIZE_NONE);
	SDL_SetBooleanProperty(props, SDL_PROP_TEXTINPUT_AUTOCORRECT_BOOLEAN, false);
	SDL_SetBooleanProperty(props, SDL_PROP_TEXTINPUT_MULTILINE_BOOLEAN, false);
	SDL_StartTextInputWithProperties(window, props);
	SDL_DestroyProperties(props);
}

static void TieIos_Tap(TieInputAction action) {
	TieInputActions_DispatchController(action, true);
	TieInputActions_DispatchController(action, false);
}

- (void)press:(BOOL)down {
	if (down == self.held)
		return;
	self.held = down;
	switch (self.kind) {
		case TIE_IOS_BUTTON_KEYBOARD:
			if (down)
				TieIos_ToggleKeyboard();
			break;
		case TIE_IOS_BUTTON_TOGGLE:
			if (down && self.toggle)
				self.toggle();
			break;
		case TIE_IOS_BUTTON_ENTER:
			if (down)
				TieInput_EnqueueKey(13);
			break;
		case TIE_IOS_BUTTON_TAP_HOLD:
			/* The hold fires from -tick:; a release before then is a tap. */
			if (down) {
				self.pressTime = CACurrentMediaTime();
				self.holdFired = NO;
			} else if (!self.holdFired) {
				TieIos_Tap(self.action);
			}
			self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
			break;
		case TIE_IOS_BUTTON_REPEAT:
			self.nextRepeat = CACurrentMediaTime() + 0.35;
			/* fall through */
		case TIE_IOS_BUTTON_ACTION:
			TieInputActions_DispatchController(self.action, down);
			break;
	}
}

/* Once per frame: repeats and holds. */
- (void)tick:(CFTimeInterval)now {
	if (!self.held)
		return;
	if (self.kind == TIE_IOS_BUTTON_TAP_HOLD && !self.holdFired && now - self.pressTime >= TIE_IOS_HOLD_SECONDS) {
		self.holdFired = YES;
		TieIos_Tap(self.holdAction);
		self.layer.borderColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.4 alpha:0.9].CGColor;
	} else if (self.kind == TIE_IOS_BUTTON_REPEAT && now >= self.nextRepeat) {
		TieInputActions_DispatchController(self.action, false);
		TieInputActions_DispatchController(self.action, true);
		/* About a held desktop key's repeat rate. */
		self.nextRepeat = now + 0.04;
	}
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	ios_controller_in_use = false;
	[self press:YES];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	[self press:NO];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	[self press:NO];
}

@end

/* ---------------- Throttle slider ---------------- */

/* A vertical throttle: full at the top. While a finger is on it, it sets the
 * virtual gamepad's throttle axis; otherwise it follows the craft, so it
 * stays right after MATCH or the throttle buttons. */
@interface TieThrottleSlider : UIView
@property(nonatomic) CGFloat value;
@property(nonatomic) BOOL dragging;
@property(nonatomic, strong) CALayer* fill;
@property(nonatomic, strong) CALayer* handle;
@property(nonatomic, strong) UILabel* label;
@end

static void TieIos_SetThrottleAxis(float value);

@implementation TieThrottleSlider

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.layer.borderWidth = 1.5;
		self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
		self.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.3];
		self.clipsToBounds = YES;
		_fill = [CALayer layer];
		_fill.backgroundColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:0.35].CGColor;
		_handle = [CALayer layer];
		_handle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
		[self.layer addSublayer:_fill];
		[self.layer addSublayer:_handle];
		_label = [[UILabel alloc] initWithFrame:CGRectZero];
		_label.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
		_label.textAlignment = NSTextAlignmentCenter;
		_label.adjustsFontSizeToFitWidth = YES;
		_label.minimumScaleFactor = 0.5;
		_label.numberOfLines = 2;
		[self addSubview:_label];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	self.layer.cornerRadius = MIN(12.0, self.bounds.size.width * 0.3);
	_label.frame = CGRectMake(2, 4, self.bounds.size.width - 4, 30);
	_label.font = [UIFont boldSystemFontOfSize:11.0];
	[self redraw];
}

- (void)redraw {
	const CGSize size = self.bounds.size;
	const CGFloat top = 36.0;
	const CGFloat travel = MAX(1.0, size.height - top - 6.0);
	const CGFloat y = top + travel * (1.0 - self.value);
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.fill.frame = CGRectMake(0, y, size.width, size.height - y);
	self.handle.frame = CGRectMake(4, y - 3, size.width - 8, 6);
	self.handle.cornerRadius = 3;
	[CATransaction commit];
	self.label.text = [NSString stringWithFormat:@"THR\n%d%%", (int)lround(self.value * 100.0)];
}

- (void)setValue:(CGFloat)value {
	_value = MAX(0.0, MIN(1.0, value));
	[self redraw];
}

- (void)follow:(CGFloat)value {
	if (!self.dragging && fabs(value - self.value) > 0.004)
		self.value = value;
}

- (void)trackTouch:(UITouch*)touch {
	const CGFloat top = 36.0;
	const CGFloat travel = MAX(1.0, self.bounds.size.height - top - 6.0);
	self.value = 1.0 - ([touch locationInView:self].y - top) / travel;
	TieIos_SetThrottleAxis((float)self.value);
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	ios_controller_in_use = false;
	self.dragging = YES;
	[self trackTouch:touches.anyObject];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	[self trackTouch:touches.anyObject];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	self.dragging = NO;
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	self.dragging = NO;
}

@end

/* ---------------- Overlay ---------------- */

/* A group of buttons that opens beside the left bar. */
@interface TieTouchGroup : NSObject
/* Saved open across launches when set. */
@property(nonatomic, copy) NSString* key;
/* A top-row submenu: opens below its toggle and closes the others. */
@property(nonatomic) BOOL submenu;
@property(nonatomic, strong) TieTouchButton* toggle;
@property(nonatomic, strong) UIView* panel;
@property(nonatomic, strong) NSArray<TieTouchButton*>* buttons;
@property(nonatomic) BOOL open;
@end

@implementation TieTouchGroup
@end

@interface TieTouchOverlay : UIView
@property(nonatomic) BOOL flight;
/* Paused in the cockpit: only PAUSE (to resume) joins ESC and KEYS. */
@property(nonatomic) BOOL paused;
@property(nonatomic, strong) TieTouchButton* pauseButton;
@property(nonatomic, strong) TieTouchButton* skipButton;
/* The game picture as a fraction of the overlay's width; the buttons go in
 * the bars beside it. */
@property(nonatomic) CGFloat gameX;
@property(nonatomic) CGFloat gameWidth;
@property(nonatomic, strong) NSArray<TieTouchButton*>* buttons;
@property(nonatomic, strong) NSArray<TieTouchButton*>* leftButtons;
@property(nonatomic, strong) NSArray<TieTouchButton*>* rightButtons;
@property(nonatomic, strong) NSArray<TieTouchButton*>* topButtons;
@property(nonatomic, strong) NSArray<TieTouchGroup*>* groups;
@property(nonatomic, strong) TieTouchButton* fireButton;
@property(nonatomic, strong) TieThrottleSlider* throttle;
@property(nonatomic, weak) UITouch* stickTouch;
@property(nonatomic) CGPoint stickOrigin;
@property(nonatomic, strong) CAShapeLayer* stickBase;
@property(nonatomic, strong) CAShapeLayer* stickKnob;
@end

@implementation TieTouchOverlay

static TieTouchButton* TieIos_Button(NSString* title, TieInputAction action) {
	return [[TieTouchButton alloc] initWithTitle:title
										  action:action
											kind:TIE_IOS_BUTTON_ACTION
										   place:TIE_IOS_PLACE_FLIGHT];
}

static TieTouchButton* TieIos_RepeatButton(NSString* title, TieInputAction action) {
	return [[TieTouchButton alloc] initWithTitle:title
										  action:action
											kind:TIE_IOS_BUTTON_REPEAT
										   place:TIE_IOS_PLACE_FLIGHT];
}

/* A target memory: a tap recalls it, a hold stores the current target. */
static TieTouchButton* TieIos_PresetButton(NSString* title, TieInputAction recall, TieInputAction store) {
	TieTouchButton* button = [[TieTouchButton alloc] initWithTitle:title
															action:recall
															  kind:TIE_IOS_BUTTON_TAP_HOLD
															 place:TIE_IOS_PLACE_FLIGHT];
	button.holdAction = store;
	return button;
}

- (TieTouchGroup*)groupWithTitle:(NSString*)title key:(NSString*)key buttons:(NSArray<TieTouchButton*>*)buttons {
	TieTouchGroup* group = [[TieTouchGroup alloc] init];
	group.key = key;
	group.buttons = buttons;
	group.toggle = [[TieTouchButton alloc] initWithTitle:title
												  action:TIE_INPUT_ACTION_NONE
													kind:TIE_IOS_BUTTON_TOGGLE
												   place:TIE_IOS_PLACE_FLIGHT];
	group.panel = [[UIView alloc] initWithFrame:CGRectZero];
	group.panel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
	group.panel.layer.cornerRadius = 12.0;
	for (TieTouchButton* button in buttons)
		[group.panel addSubview:button];
	group.open = key && [[NSUserDefaults standardUserDefaults] boolForKey:key];
	__weak TieTouchOverlay* weak_self = self;
	__weak TieTouchGroup* weak_group = group;
	group.toggle.toggle = ^{
		TieTouchGroup* toggled = weak_group;
		toggled.open = !toggled.open;
		if (toggled.open && toggled.submenu)
			for (TieTouchGroup* other in weak_self.groups)
				if (other != toggled && other.submenu)
					other.open = NO;
		if (toggled.key)
			[[NSUserDefaults standardUserDefaults] setBool:toggled.open forKey:toggled.key];
		[weak_self updateVisibility];
		[weak_self setNeedsLayout];
	};
	return group;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.multipleTouchEnabled = YES;
		self.backgroundColor = UIColor.clearColor;
		self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

		TieTouchButton* escape = [[TieTouchButton alloc] initWithTitle:@"ESC"
																action:TIE_INPUT_ACTION_ESCAPE
																  kind:TIE_IOS_BUTTON_ACTION
																 place:TIE_IOS_PLACE_ALWAYS];
		TieTouchButton* keyboard = [[TieTouchButton alloc] initWithTitle:@"KEYS"
																  action:TIE_INPUT_ACTION_NONE
																	kind:TIE_IOS_BUTTON_KEYBOARD
																   place:TIE_IOS_PLACE_ALWAYS];
		/* Power and target memories fold away behind their toggles. */
		_groups = @[
			[self groupWithTitle:@"PWR"
							 key:@"TieIosPowerOpen"
						 buttons:@[
							 TieIos_Button(@"LSR\nRATE", TIE_INPUT_ACTION_CYCLE_CANNON_RECHARGE_RATE),
							 TieIos_Button(@"SHD\nRATE", TIE_INPUT_ACTION_CYCLE_SHIELD_RECHARGE_RATE),
							 TieIos_Button(@"LSR→\nSHD", TIE_INPUT_ACTION_XFER_CANNON_TO_SHIELDS),
							 TieIos_Button(@"SHD→\nLSR", TIE_INPUT_ACTION_XFER_SHIELDS_TO_CANNON),
							 TieIos_Button(@"BEAM\nRATE", TIE_INPUT_ACTION_CYCLE_BEAM_RECHARGE_RATE),
							 TieIos_Button(@"SHLD", TIE_INPUT_ACTION_CYCLE_SHIELD_MODE),
							 TieIos_Button(@"BEAM", TIE_INPUT_ACTION_TOGGLE_BEAM),
						 ]],
			[self groupWithTitle:@"MEM"
							 key:@"TieIosMemoryOpen"
						 buttons:@[
							 TieIos_PresetButton(@"T1", TIE_INPUT_ACTION_TARGET_PRESET_RECALL_1,
												 TIE_INPUT_ACTION_TARGET_PRESET_STORE_1),
							 TieIos_PresetButton(@"T2", TIE_INPUT_ACTION_TARGET_PRESET_RECALL_2,
												 TIE_INPUT_ACTION_TARGET_PRESET_STORE_2),
							 TieIos_PresetButton(@"T3", TIE_INPUT_ACTION_TARGET_PRESET_RECALL_3,
												 TIE_INPUT_ACTION_TARGET_PRESET_STORE_3),
						 ]],
		];
		/* Enter: in a cutscene it skips the whole sequence, where a tap (a
		 * left click) only ends the current scene. Outside the cockpit it
		 * takes PWR's place. */
		_skipButton = [[TieTouchButton alloc] initWithTitle:@"SKIP"
													 action:TIE_INPUT_ACTION_NONE
													   kind:TIE_IOS_BUTTON_ENTER
													  place:TIE_IOS_PLACE_MENUS];
		/* Left bar, one column down the outer edge; the throttle beside it. */
		_leftButtons = @[ escape, keyboard, _groups[0].toggle, _groups[1].toggle ];
		/* Right bar, two to a row from the top, with FIRE below them. */
		_rightButtons = @[
			TieIos_RepeatButton(@"THR+", TIE_INPUT_ACTION_THROTTLE_UP),
			TieIos_RepeatButton(@"THR−", TIE_INPUT_ACTION_THROTTLE_DOWN),
			TieIos_Button(@"WPN", TIE_INPUT_ACTION_CYCLE_WEAPON_GROUP),
			TieIos_Button(@"LINK", TIE_INPUT_ACTION_CYCLE_WEAPON_FIRING_MODE),
			TieIos_Button(@"NEAR", TIE_INPUT_ACTION_TARGET_NEAREST_FIGHTER_OR_MINE),
			TieIos_Button(@"ATKR", TIE_INPUT_ACTION_TARGET_MY_ATTACKER),
			TieIos_Button(@"TGT◀", TIE_INPUT_ACTION_TARGET_PREV),
			TieIos_Button(@"TGT▶", TIE_INPUT_ACTION_TARGET_NEXT),
			TieIos_Button(@"MATCH", TIE_INPUT_ACTION_MATCH_SPEED),
			TieIos_Button(@"ROLL", TIE_INPUT_ACTION_TARGET_ROLL_THROTTLE_MODIFIER),
		];
		/* The top row, between the scopes: PAUSE, OK and the target viewer,
		 * with the rest in submenus that open below it, one at a time. */
		NSArray<TieTouchGroup*>* submenus = @[
			[self groupWithTitle:@"INFO ▾"
							 key:nil
						 buttons:@[
							 TieIos_Button(@"MAP", TIE_INPUT_ACTION_INFO_MAP),
							 TieIos_Button(@"GOALS", TIE_INPUT_ACTION_INFO_GOALS),
							 TieIos_Button(@"MSGS", TIE_INPUT_ACTION_INFO_MESSAGES),
							 TieIos_Button(@"DMG", TIE_INPUT_ACTION_INFO_DAMAGE),
						 ]],
			[self groupWithTitle:@"VIEW ▾"
							 key:nil
						 buttons:@[
							 TieIos_Button(@"COCKPIT", TIE_INPUT_ACTION_VIEW_TOGGLE_COCKPIT),
							 TieIos_Button(@"EXT CAM", TIE_INPUT_ACTION_VIEW_TOGGLE_EXTERNAL_CAMERA),
							 TieIos_Button(@"CAM CTRL", TIE_INPUT_ACTION_VIEW_TOGGLE_EXTERNAL_CAMERA_CONTROL),
							 TieIos_Button(@"MSL CAM", TIE_INPUT_ACTION_CYCLE_WARHEAD_VIEW),
						 ]],
			[self groupWithTitle:@"CMD ▾"
							 key:nil
						 buttons:@[
							 TieIos_Button(@"WING", TIE_INPUT_ACTION_INFO_WINGMAN_COMMANDS),
							 TieIos_Button(@"ATK TGT", TIE_INPUT_ACTION_COMM_ASSIGN_TARGET),
							 TieIos_Button(@"COVER", TIE_INPUT_ACTION_COMM_COVER_ME),
							 TieIos_Button(@"REINF", TIE_INPUT_ACTION_COMM_REINFORCEMENTS),
							 TieIos_Button(@"HYPER", TIE_INPUT_ACTION_HYPERSPACE),
						 ]],
		];
		for (TieTouchGroup* group in submenus)
			group.submenu = YES;
		_groups = [_groups arrayByAddingObjectsFromArray:submenus];
		_pauseButton = TieIos_Button(@"PAUSE", TIE_INPUT_ACTION_PAUSE);
		_topButtons = @[
			_pauseButton,
			TieIos_Button(@"OK", TIE_INPUT_ACTION_CONFIRM),
			/* The target viewer ('z'): the target from outside, with its name
			 * and weapons; again for the cockpit. */
			TieIos_Button(@"TGT VIEW", TIE_INPUT_ACTION_TOGGLE_THREAT_DISPLAY),
			submenus[0].toggle,
			submenus[1].toggle,
			submenus[2].toggle,
		];
		_fireButton = TieIos_Button(@"FIRE", TIE_INPUT_ACTION_FIRE_WEAPON);
		NSMutableArray<TieTouchButton*>* all = [NSMutableArray array];
		[all addObjectsFromArray:_leftButtons];
		[all addObjectsFromArray:_rightButtons];
		[all addObjectsFromArray:_topButtons];
		[all addObject:_fireButton];
		[all addObject:_skipButton];
		for (TieTouchButton* button in all)
			[self addSubview:button];
		for (TieTouchGroup* group in _groups) {
			[self addSubview:group.panel];
			[all addObjectsFromArray:group.buttons];
		}
		_buttons = all;
		_throttle = [[TieThrottleSlider alloc] initWithFrame:CGRectZero];
		[self addSubview:_throttle];

		_stickBase = [CAShapeLayer layer];
		_stickBase.fillColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
		_stickBase.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
		_stickBase.lineWidth = 1.5;
		_stickKnob = [CAShapeLayer layer];
		_stickKnob.fillColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
		[self.layer addSublayer:_stickBase];
		[self.layer addSublayer:_stickKnob];
		_flight = YES;
		[self setFlight:NO paused:NO];
	}
	return self;
}

- (CGFloat)stickRadius {
	return MAX(50.0, self.bounds.size.height * 0.16);
}

- (void)setGameX:(CGFloat)x width:(CGFloat)width {
	if (fabs(x - self.gameX) < 0.001 && fabs(width - self.gameWidth) < 0.001)
		return;
	self.gameX = x;
	self.gameWidth = width;
	[self setNeedsLayout];
}

/* The game picture in points: what the presentation reported, or a centered
 * 4:3 frame before it has. */
- (CGRect)gameRect {
	const CGSize size = self.bounds.size;
	if (self.gameWidth > 0.0)
		return CGRectMake(size.width * self.gameX, 0.0, size.width * self.gameWidth, size.height);
	const CGFloat width = MIN(size.width, size.height * 4.0 / 3.0);
	return CGRectMake((size.width - width) / 2, 0.0, width, size.height);
}

/* Two columns from the top. */
static void TieIos_LayoutPairs(NSArray<TieTouchButton*>* buttons, CGFloat x, CGFloat y, CGFloat cell,
							   CGFloat gap) {
	for (NSUInteger index = 0; index < buttons.count; ++index)
		buttons[index].frame = CGRectMake(x + (index % 2) * (cell + gap), y + (index / 2) * (cell + gap), cell, cell);
}

- (void)layoutSubviews {
	[super layoutSubviews];
	const UIEdgeInsets safe = self.safeAreaInsets;
	const CGRect area = UIEdgeInsetsInsetRect(self.bounds, safe);
	const CGRect game = [self gameRect];
	const CGFloat gap = 6.0;
	const CGFloat top = area.origin.y + gap;
	const CGFloat height = area.size.height - gap * 2;

	/* The bars beside the picture hold two columns each. Where they are too
	 * narrow, as on an iPad, the columns overlap the picture's edges. */
	const NSUInteger right_rows = (self.rightButtons.count + 1) / 2;
	const CGFloat fire_rows = 1.8;
	const CGFloat by_height = (height - gap * right_rows) / (right_rows + fire_rows);
	const CGFloat left_bar = CGRectGetMinX(game) - CGRectGetMinX(area);
	const CGFloat right_bar = CGRectGetMaxX(area) - CGRectGetMaxX(game);
	const CGFloat by_width = (MIN(left_bar, right_bar) - gap * 3) / 2;
	const CGFloat cell = MIN(64.0, MAX(36.0, MIN(by_width, by_height)));
	const CGFloat column_width = cell * 2 + gap;
	const bool in_bars = by_width >= 36.0;
	const CGFloat left_x = in_bars ? CGRectGetMinX(area) + (left_bar - column_width) / 2 : CGRectGetMinX(area) + gap;
	const CGFloat right_x = in_bars ? CGRectGetMaxX(game) + (right_bar - column_width) / 2
									: CGRectGetMaxX(area) - gap - column_width;

	/* Left: buttons down the outer column, the throttle in the inner one. */
	for (NSUInteger index = 0; index < self.leftButtons.count; ++index)
		self.leftButtons[index].frame = CGRectMake(left_x, top + index * (cell + gap), cell, cell);
	self.skipButton.frame = self.leftButtons[2].frame;
	self.throttle.frame = CGRectMake(left_x + cell + gap, top, cell, MAX(cell * 2.5, height / 3));

	/* Each power or memory panel opens beside its toggle, inside the screen. */
	for (TieTouchGroup* group in self.groups) {
		if (group.submenu)
			continue;
		const NSUInteger rows = (group.buttons.count + 1) / 2;
		const CGSize panel = CGSizeMake(column_width + gap * 2, rows * (cell + gap) + gap);
		CGFloat y = CGRectGetMinY(group.toggle.frame) - gap;
		y = MAX(top, MIN(y, CGRectGetMaxY(area) - gap - panel.height));
		group.panel.frame = CGRectMake(CGRectGetMaxX(self.throttle.frame) + gap, y, panel.width, panel.height);
		TieIos_LayoutPairs(group.buttons, gap, gap, cell, gap);
	}

	TieIos_LayoutPairs(self.rightButtons, right_x, top, cell, gap);
	const CGFloat fire_top = top + right_rows * (cell + gap);
	const CGFloat fire = MIN(column_width, CGRectGetMaxY(area) - gap - fire_top);
	self.fireButton.frame = CGRectMake(right_x + (column_width - fire) / 2, fire_top, fire, fire);

	/* One row across the middle of the picture's top edge; a submenu opens
	 * as a row below its toggle. */
	const NSUInteger row_count = self.topButtons.count;
	const CGFloat row_height = MAX(28.0, MIN(36.0, area.size.height * 0.08));
	const CGFloat row_width = MIN(80.0, (game.size.width * 0.62 - gap * (row_count - 1)) / row_count);
	const CGFloat row_x = CGRectGetMidX(game) - (row_width * row_count + gap * (row_count - 1)) / 2;
	for (NSUInteger index = 0; index < row_count; ++index)
		self.topButtons[index].frame =
			CGRectMake(row_x + index * (row_width + gap), top, row_width, row_height);
	for (TieTouchGroup* group in self.groups) {
		if (!group.submenu)
			continue;
		const NSUInteger count = group.buttons.count;
		const CGSize panel = CGSizeMake(count * (row_width + gap) + gap, row_height + gap * 2);
		CGFloat x = CGRectGetMidX(group.toggle.frame) - panel.width / 2;
		x = MAX(CGRectGetMinX(game) + gap, MIN(x, CGRectGetMaxX(game) - gap - panel.width));
		group.panel.frame = CGRectMake(x, CGRectGetMaxY(group.toggle.frame) + gap, panel.width, panel.height);
		for (NSUInteger index = 0; index < count; ++index)
			group.buttons[index].frame =
				CGRectMake(gap + index * (row_width + gap), gap, row_width, row_height);
	}
}

- (void)updateVisibility {
	for (TieTouchButton* button in self.buttons) {
		BOOL visible = button.place == TIE_IOS_PLACE_MENUS
						   ? !self.flight && !self.paused
						   : button.place == TIE_IOS_PLACE_ALWAYS || self.flight ||
								 (self.paused && button == self.pauseButton);
		for (TieTouchGroup* group in self.groups)
			if ([group.buttons containsObject:button])
				visible = visible && group.open;
		if (!visible && button.held)
			[button press:NO];
		button.hidden = !visible;
	}
	for (TieTouchGroup* group in self.groups) {
		group.panel.hidden = !(self.flight && group.open);
		[group.toggle setOpen:group.open];
	}
	self.throttle.hidden = !self.flight;
}

- (void)setFlight:(BOOL)flight paused:(BOOL)paused {
	if (flight == _flight && paused == _paused)
		return;
	_flight = flight;
	_paused = paused;
	[self updateVisibility];
	if (!flight)
		[self endStick];
}

- (void)followThrottle:(CGFloat)value {
	[self.throttle follow:value];
}

- (void)setGamepadConnected:(BOOL)connected {
	if (connected != self.hidden)
		SDL_Log("[tie-ios] touch controls %s", connected ? "hidden: a game controller is in use" : "shown");
	self.hidden = connected;
	if (connected) {
		for (TieTouchButton* button in self.buttons)
			if (button.held)
				[button press:NO];
		[self endStick];
	}
}

- (void)tickButtons {
	const CFTimeInterval now = CACurrentMediaTime();
	for (TieTouchButton* button in self.buttons)
		[button tick:now];
}

/* Outside flight the overlay passes every touch but its buttons to SDL. */
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
	UIView* hit = [super hitTest:point withEvent:event];
	return hit == self && !self.flight ? nil : hit;
}

- (void)drawStickAt:(CGPoint)point {
	const CGFloat radius = [self stickRadius];
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.stickBase.path = [UIBezierPath bezierPathWithArcCenter:self.stickOrigin
														radius:radius
													startAngle:0
													  endAngle:2 * M_PI
													 clockwise:YES]
							  .CGPath;
	self.stickKnob.path = [UIBezierPath bezierPathWithArcCenter:point
														radius:radius * 0.4
													startAngle:0
													  endAngle:2 * M_PI
													 clockwise:YES]
							  .CGPath;
	self.stickBase.hidden = NO;
	self.stickKnob.hidden = NO;
	[CATransaction commit];
}

- (void)moveStick:(CGPoint)point {
	const CGFloat radius = [self stickRadius];
	CGFloat dx = (point.x - self.stickOrigin.x) / radius;
	CGFloat dy = (point.y - self.stickOrigin.y) / radius;
	const CGFloat length = hypot(dx, dy);
	if (length > 1.0) {
		dx /= length;
		dy /= length;
	}
	TieIos_SetStick((float)dx, (float)dy);
	[self drawStickAt:CGPointMake(self.stickOrigin.x + dx * radius, self.stickOrigin.y + dy * radius)];
}

- (void)endStick {
	self.stickTouch = nil;
	TieIos_SetStick(0.0f, 0.0f);
	self.stickBase.hidden = YES;
	self.stickKnob.hidden = YES;
}

/* The stick starts wherever a thumb lands outside the buttons. */
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	ios_controller_in_use = false;
	for (UITouch* touch in touches) {
		if (self.stickTouch || !self.flight)
			break;
		self.stickTouch = touch;
		self.stickOrigin = [touch locationInView:self];
		[self moveStick:self.stickOrigin];
	}
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	if (self.stickTouch && [touches containsObject:self.stickTouch])
		[self moveStick:[self.stickTouch locationInView:self]];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	if (self.stickTouch && [touches containsObject:self.stickTouch])
		[self endStick];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	[self touchesEnded:touches withEvent:event];
}

@end

/* ---------------- Lifecycle ---------------- */

static TieTouchOverlay* ios_overlay;

static SDL_Window* TieIos_Window(void) {
	int count = 0;
	SDL_Window** windows = SDL_GetWindows(&count);
	SDL_Window* window = windows && count > 0 ? windows[0] : NULL;
	SDL_free(windows);
	return window;
}

void TieIos_Init(void) {
	SDL_Window* window = TieIos_Window();
	if (!window) {
		SDL_Log("[tie-ios] no window for the touch controls");
		return;
	}
	/* Aeron starts text input, which raises the screen keyboard on iOS. */
	SDL_StopTextInput(window);

	UIWindow* ui_window = (__bridge UIWindow*)SDL_GetPointerProperty(
		SDL_GetWindowProperties(window), SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
	UIView* root = ui_window.rootViewController.view;
	if (!root) {
		SDL_Log("[tie-ios] no UIKit view for the touch controls");
		return;
	}
	SDL_AddEventWatch(TieIos_WatchEvent, NULL);
	ios_overlay = [[TieTouchOverlay alloc] initWithFrame:root.bounds];
	[root addSubview:ios_overlay];
	TieIos_Frame();
}

void TieIos_Frame(void) {
	if (!ios_overlay)
		return;
	const bool hardware = ios_controller_in_use;
	if (hardware)
		TieIos_DetachGamepad();
	else
		TieIos_AttachGamepad();
	[ios_overlay setGamepadConnected:hardware];

	const TieSnapshot* snapshot = TieSnapshot_Current();
	const bool cockpit = snapshot && snapshot->scene_kind == TIE_SCENE_FLIGHT &&
						 snapshot->flight_screen == TIE_FLIGHT_SCREEN_NORMAL && !TieSettings_Open();
	const bool paused = cockpit && TieFlightPause_IsActive();
	const bool flight = cockpit && !paused;
	[ios_overlay setFlight:flight paused:paused];
	const TiePresentationLayout* presentation = TiePresentation_Layout();
	if (presentation && presentation->frame.width > 0)
		[ios_overlay setGameX:(CGFloat)presentation->modern.x / presentation->frame.width
						width:(CGFloat)presentation->modern.width / presentation->frame.width];
	[ios_overlay tickButtons];
	TieIos_MapTouchThrottle();
	uint16_t throttle;
	if (flight && TieUserTiming_PlayerThrottle(&throttle))
		[ios_overlay followThrottle:(CGFloat)throttle / UINT16_MAX];
	[ios_overlay.superview bringSubviewToFront:ios_overlay];
}

void TieIos_Shutdown(void) {
	SDL_RemoveEventWatch(TieIos_WatchEvent, NULL);
	[ios_overlay removeFromSuperview];
	ios_overlay = nil;
	TieIos_DetachGamepad();
}
