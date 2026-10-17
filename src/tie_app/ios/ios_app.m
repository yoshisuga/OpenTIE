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
#include "tie_runtime/runtime/quicksave.h"
#include "tie_runtime/snapshot/snapshot.h"
#include "tie_runtime/timing/user_timing.h"

#include <SDL3/SDL.h>

#import <CoreMotion/CoreMotion.h>
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

/* The flight stick is the touch stick plus the gyro, each -1..1. */
static float ios_touch_x, ios_touch_y;
static float ios_gyro_x, ios_gyro_y;

static void TieIos_ApplyStick(void) {
	if (!ios_gamepad)
		return;
	const float x = fmaxf(-1.0f, fminf(1.0f, ios_touch_x + ios_gyro_x));
	const float y = fmaxf(-1.0f, fminf(1.0f, ios_touch_y + ios_gyro_y));
	SDL_SetJoystickVirtualAxis(ios_gamepad, SDL_GAMEPAD_AXIS_LEFTX, (Sint16)lroundf(x * SDL_JOYSTICK_AXIS_MAX));
	SDL_SetJoystickVirtualAxis(ios_gamepad, SDL_GAMEPAD_AXIS_LEFTY, (Sint16)lroundf(y * SDL_JOYSTICK_AXIS_MAX));
}

static void TieIos_SetStick(float x, float y) {
	ios_touch_x = x;
	ios_touch_y = y;
	TieIos_ApplyStick();
}

/* ---------------- Gyro aiming ---------------- */

/* Turning the phone turns the ship: the gyro's rotation rate deflects the
 * stick, so the ship follows the phone and stops when it stops, with no
 * drift to recenter. */
static CMMotionManager* ios_motion;
static bool ios_gyro_on;
static NSString* const TieIosGyroKey = @"TieIosGyro";
static const double TIE_IOS_GYRO_FULL_RATE = 1.5;  /* rad/s for a full deflection */
static const double TIE_IOS_GYRO_DEADZONE = 0.03; /* rad/s of hand tremor ignored */

static void TieIos_SetGyro(bool on) {
	ios_gyro_on = on;
	[[NSUserDefaults standardUserDefaults] setBool:on forKey:TieIosGyroKey];
	if (!ios_motion)
		ios_motion = [[CMMotionManager alloc] init];
	if (on && ios_motion.deviceMotionAvailable) {
		ios_motion.deviceMotionUpdateInterval = 1.0 / 60.0;
		[ios_motion startDeviceMotionUpdates];
	} else {
		[ios_motion stopDeviceMotionUpdates];
	}
}

static double TieIos_GyroAxis(double rate) {
	if (fabs(rate) < TIE_IOS_GYRO_DEADZONE)
		return 0.0;
	return (rate - copysign(TIE_IOS_GYRO_DEADZONE, rate)) / TIE_IOS_GYRO_FULL_RATE;
}

/* Rotation about the screen's vertical axis yaws; about its horizontal axis
 * pitches. Which device axis is which depends on the landscape side. */
static void TieIos_UpdateGyro(bool flight, UIInterfaceOrientation orientation) {
	CMDeviceMotion* motion = ios_gyro_on && flight ? ios_motion.deviceMotion : nil;
	if (!motion) {
		ios_gyro_x = ios_gyro_y = 0.0f;
		return;
	}
	const CMRotationRate rate = motion.rotationRate;
	const bool home_right = orientation == UIInterfaceOrientationLandscapeRight;
	const double about_up = home_right ? rate.x : -rate.x;
	const double about_right = home_right ? -rate.y : rate.y;
	ios_gyro_x = (float)TieIos_GyroAxis(-about_up);
	ios_gyro_y = (float)TieIos_GyroAxis(about_right);
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
	TIE_IOS_BUTTON_WHEEL,    /* an action on a tap; hold or slide out for a wheel */
} TieIosButtonKind;

/* The screens a button shows on, as a mask. */
typedef enum TieIosButtonPlace {
	TIE_IOS_PLACE_MENUS = 1 << 0,  /* everything but the screens below */
	TIE_IOS_PLACE_FLIGHT = 1 << 1, /* the cockpit */
	TIE_IOS_PLACE_PAUSED = 1 << 2, /* the cockpit, paused */
	TIE_IOS_PLACE_MAP = 1 << 3,    /* the in-flight map */
	TIE_IOS_PLACE_ALWAYS = TIE_IOS_PLACE_MENUS | TIE_IOS_PLACE_FLIGHT | TIE_IOS_PLACE_PAUSED | TIE_IOS_PLACE_MAP,
} TieIosButtonPlace;

static const CFTimeInterval TIE_IOS_HOLD_SECONDS = 0.5;

/* Each kind of control has a color, on its outline and as a soft fill.
 * Amber is kept for open and holding, red in a wheel for danger. */
typedef enum TieIosCategory {
	TIE_IOS_CATEGORY_GAME,      /* gray: ESC, KEYS, PAUSE, OK, SKIP, MISSION, CHKPT */
	TIE_IOS_CATEGORY_WEAPONS,   /* coral: FIRE, WPN, LINK */
	TIE_IOS_CATEGORY_TARGETING, /* green: TGT and the target memories */
	TIE_IOS_CATEGORY_FLIGHT,    /* blue: throttle, MATCH, ROLL, GYRO */
	TIE_IOS_CATEGORY_POWER,     /* violet: recharge rates, transfers, shields */
	TIE_IOS_CATEGORY_INFO,      /* teal: INFO, VIEW and CMD, and LOOK */
} TieIosCategory;

static UIColor* TieIos_CategoryColor(TieIosCategory category) {
	switch (category) {
		case TIE_IOS_CATEGORY_WEAPONS:
			return [UIColor colorWithRed:1.00 green:0.42 blue:0.38 alpha:1.0];
		case TIE_IOS_CATEGORY_TARGETING:
			return [UIColor colorWithRed:0.45 green:0.85 blue:0.40 alpha:1.0];
		case TIE_IOS_CATEGORY_FLIGHT:
			return [UIColor colorWithRed:0.40 green:0.62 blue:1.00 alpha:1.0];
		case TIE_IOS_CATEGORY_POWER:
			return [UIColor colorWithRed:0.72 green:0.52 blue:1.00 alpha:1.0];
		case TIE_IOS_CATEGORY_INFO:
			return [UIColor colorWithRed:0.30 green:0.80 blue:0.85 alpha:1.0];
		case TIE_IOS_CATEGORY_GAME:
			break;
	}
	return [UIColor colorWithWhite:0.80 alpha:1.0];
}

static UIColor* TieIos_Amber(void) { return [UIColor colorWithRed:1.0 green:0.8 blue:0.3 alpha:0.95]; }
static const CFTimeInterval TIE_IOS_WHEEL_SECONDS = 0.3;

/* Haptics: a light tap as a wheel opens, a tick as its choice changes, a
 * firmer tap when one is taken, and a success buzz when a hold stores. */
static UIImpactFeedbackGenerator* ios_haptic_light;
static UIImpactFeedbackGenerator* ios_haptic_medium;
static UISelectionFeedbackGenerator* ios_haptic_select;
static UINotificationFeedbackGenerator* ios_haptic_notify;

static void TieIos_PrepareHaptics(void) {
	if (!ios_haptic_light) {
		ios_haptic_light = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
		ios_haptic_medium = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
		ios_haptic_select = [[UISelectionFeedbackGenerator alloc] init];
		ios_haptic_notify = [[UINotificationFeedbackGenerator alloc] init];
	}
	[ios_haptic_light prepare];
	[ios_haptic_select prepare];
}

/* ---------------- Choice wheel ---------------- */

/* The ring of choices a wheel button opens. The choice under the finger is
 * picked when it lifts; the center, marked ✕, or anywhere short of the ring
 * picks none. Nothing is picked until the finger has moved, and a dangerous
 * choice (eject, end mission) must be held until it arms. */
static const CGFloat TIE_IOS_WHEEL_MOVE = 14.0;     /* points before any pick */
static const CFTimeInterval TIE_IOS_WHEEL_ARM = 0.6; /* seconds on a dangerous choice */

@interface TieChoiceWheel : UIView
@property(nonatomic, strong) NSArray<NSString*>* titles;
@property(nonatomic, strong) NSIndexSet* dangerous;
/* Choices shown dimmed that cannot be taken, such as an empty slot. */
@property(nonatomic, strong) NSIndexSet* disabled;
@property(nonatomic, strong) NSArray<UILabel*>* labels;
@property(nonatomic, strong) UILabel* cancelLabel;
@property(nonatomic, strong) CAShapeLayer* disc;
@property(nonatomic) CGPoint hub;
@property(nonatomic) CGPoint openPoint;
@property(nonatomic) BOOL moved;
@property(nonatomic) CGFloat radius;
@property(nonatomic) NSInteger selection;
@property(nonatomic) CFTimeInterval selectedAt;
@property(nonatomic) BOOL armed;
@end

@implementation TieChoiceWheel

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.userInteractionEnabled = NO;
		self.hidden = YES;
		self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		_disc = [CAShapeLayer layer];
		_disc.fillColor = [UIColor colorWithWhite:0.0 alpha:0.55].CGColor;
		_disc.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
		_disc.lineWidth = 1.5;
		[self.layer addSublayer:_disc];
		_cancelLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
		_cancelLabel.text = @"✕";
		_cancelLabel.textAlignment = NSTextAlignmentCenter;
		_cancelLabel.font = [UIFont boldSystemFontOfSize:20.0];
		_cancelLabel.layer.cornerRadius = 22.0;
		_cancelLabel.layer.borderWidth = 1.5;
		_cancelLabel.clipsToBounds = YES;
		[self addSubview:_cancelLabel];
	}
	return self;
}

/* Opens around origin, moved in from the edges as needed; the finger starts
 * at point. */
- (void)showFrom:(CGPoint)origin
		   finger:(CGPoint)point
		   titles:(NSArray<NSString*>*)titles
		dangerous:(NSIndexSet*)dangerous
		 disabled:(NSIndexSet*)disabled {
	for (UILabel* label in self.labels)
		[label removeFromSuperview];
	self.titles = titles;
	self.dangerous = dangerous;
	self.disabled = disabled;
	self.openPoint = point;
	self.moved = NO;
	const CGSize size = self.bounds.size;
	const CGSize pill = CGSizeMake(70.0, 30.0);
	/* Far enough out that the choices do not touch, within the screen. */
	self.radius = MIN(MAX(110.0, titles.count * (pill.width + 6.0) / (2.0 * M_PI)), size.height * 0.36);
	const CGFloat reach = self.radius + pill.width / 2 + 4.0;
	self.hub = CGPointMake(MAX(reach, MIN(origin.x, size.width - reach)),
						   MAX(self.radius + pill.height, MIN(origin.y, size.height - self.radius - pill.height)));
	NSMutableArray<UILabel*>* labels = [NSMutableArray array];
	for (NSUInteger index = 0; index < titles.count; ++index) {
		const CGFloat angle = -M_PI_2 + index * 2.0 * M_PI / titles.count;
		UILabel* label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, pill.width, pill.height)];
		label.center = CGPointMake(self.hub.x + cos(angle) * self.radius, self.hub.y + sin(angle) * self.radius);
		label.text = titles[index];
		label.textAlignment = NSTextAlignmentCenter;
		label.font = [UIFont boldSystemFontOfSize:13.0];
		label.adjustsFontSizeToFitWidth = YES;
		label.minimumScaleFactor = 0.6;
		label.textColor = UIColor.whiteColor;
		label.alpha = [disabled containsIndex:index] ? 0.35 : 1.0;
		label.layer.cornerRadius = pill.height / 2;
		label.layer.borderWidth = 1.5;
		label.layer.borderColor = [dangerous containsIndex:index]
									  ? [UIColor colorWithRed:1.0 green:0.4 blue:0.35 alpha:0.9].CGColor
									  : [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
		label.clipsToBounds = YES;
		[self addSubview:label];
		[labels addObject:label];
	}
	self.labels = labels;
	self.cancelLabel.center = self.hub;
	self.disc.path = [UIBezierPath bezierPathWithArcCenter:self.hub
													radius:self.radius + pill.height
												startAngle:0
												  endAngle:2 * M_PI
												 clockwise:YES]
						 .CGPath;
	self.selection = -1;
	self.armed = NO;
	[self highlight];
	self.hidden = NO;
	[self.superview bringSubviewToFront:self];
}

- (void)track:(CGPoint)point {
	if (!self.moved && hypot(point.x - self.openPoint.x, point.y - self.openPoint.y) < TIE_IOS_WHEEL_MOVE)
		return;
	self.moved = YES;
	const CGFloat dx = point.x - self.hub.x, dy = point.y - self.hub.y;
	NSInteger selection = -1;
	if (hypot(dx, dy) > self.radius * 0.45 && self.titles.count) {
		const CGFloat step = 2.0 * M_PI / self.titles.count;
		const CGFloat angle = atan2(dy, dx) + M_PI_2;
		selection = (NSInteger)lround(angle / step) % (NSInteger)self.titles.count;
		if (selection < 0)
			selection += self.titles.count;
		if ([self.disabled containsIndex:selection])
			selection = -1;
	}
	if (selection != self.selection) {
		self.selection = selection;
		self.selectedAt = CACurrentMediaTime();
		self.armed = NO;
		[self highlight];
		if (selection >= 0) {
			[ios_haptic_select selectionChanged];
			[ios_haptic_select prepare];
		}
	}
}

/* Once per frame while open: a dangerous choice arms after a dwell. */
- (void)tick:(CFTimeInterval)now {
	if (self.selection < 0 || self.armed || ![self.dangerous containsIndex:self.selection] ||
		now - self.selectedAt < TIE_IOS_WHEEL_ARM)
		return;
	self.armed = YES;
	[ios_haptic_notify notificationOccurred:UINotificationFeedbackTypeWarning];
	[self highlight];
}

/* The choice to take on release, or -1. */
- (NSInteger)committed {
	if (self.selection < 0 || ([self.dangerous containsIndex:self.selection] && !self.armed))
		return -1;
	return self.selection;
}

- (void)highlight {
	for (NSUInteger index = 0; index < self.labels.count; ++index) {
		UIColor* color = [UIColor colorWithWhite:0.2 alpha:0.8];
		if ((NSInteger)index == self.selection) {
			if (![self.dangerous containsIndex:index])
				color = [UIColor colorWithRed:1.0 green:0.8 blue:0.3 alpha:0.75];
			else
				color = self.armed ? [UIColor colorWithRed:0.95 green:0.2 blue:0.15 alpha:0.9]
								   : [UIColor colorWithRed:0.5 green:0.15 blue:0.12 alpha:0.85];
		}
		self.labels[index].backgroundColor = color;
	}
	const BOOL none = self.selection < 0;
	self.cancelLabel.backgroundColor = none ? [UIColor colorWithWhite:1.0 alpha:0.3] : [UIColor colorWithWhite:0.2 alpha:0.8];
	self.cancelLabel.textColor = [UIColor colorWithWhite:1.0 alpha:none ? 1.0 : 0.6];
	self.cancelLabel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
}

- (void)dismiss {
	self.hidden = YES;
}

@end

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
@property(nonatomic, strong) UIColor* tint;
@property(nonatomic) BOOL open;
/* MENU's icon: a plus while collapsed, turned to a cross while open. */
@property(nonatomic, strong) UIImageView* chevron;
/* A wheel button's ring: titles and the actions they send. */
@property(nonatomic, strong) NSArray<NSString*>* choiceTitles;
@property(nonatomic, strong) NSIndexSet* dangerousChoices;
/* Asked as the wheel opens: the choices to show dimmed. */
@property(nonatomic, copy) NSIndexSet* (^disabledChoices)(void);
@property(nonatomic) TieInputAction* choiceActions;
@property(nonatomic, weak) TieChoiceWheel* wheel;
@property(nonatomic) BOOL wheelOpen;
@property(nonatomic) CGPoint lastPoint;
/* Buttons with a hold: a short arc on the outline at rest, and a ring that
 * fills around it while held, completing as the hold takes effect. */
@property(nonatomic, strong) CAShapeLayer* holdMark;
@property(nonatomic, strong) CAShapeLayer* holdRing;
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
		_tint = TieIos_CategoryColor(TIE_IOS_CATEGORY_GAME);
		_label = [[UILabel alloc] initWithFrame:CGRectZero];
		_label.text = title;
		_label.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
		_label.textAlignment = NSTextAlignmentCenter;
		_label.adjustsFontSizeToFitWidth = YES;
		_label.minimumScaleFactor = 0.4;
		_label.numberOfLines = 2;
		[self addSubview:_label];
		[self setHeld:NO];
		[self restBorder];
	}
	return self;
}

- (void)addChevron {
	UIImageSymbolConfiguration* weight = [UIImageSymbolConfiguration configurationWithWeight:UIImageSymbolWeightBold];
	self.chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"plus" withConfiguration:weight]];
	self.chevron.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
	self.chevron.contentMode = UIViewContentModeScaleAspectFit;
	[self addSubview:self.chevron];
	[self setNeedsLayout];
}

- (void)turnChevron:(BOOL)open {
	self.chevron.transform = open ? CGAffineTransformMakeRotation((CGFloat)M_PI_4) : CGAffineTransformIdentity;
}

- (void)setCategory:(TieIosCategory)category {
	self.tint = TieIos_CategoryColor(category);
	[self setHeld:self.held];
	[self restBorder];
}

/* The outline at rest: amber while a group or toggle is open. */
- (void)restBorder {
	self.layer.borderWidth = self.open ? 2.5 : 1.5;
	self.layer.borderColor = self.open ? TieIos_Amber().CGColor : [self.tint colorWithAlphaComponent:0.8].CGColor;
}

- (BOOL)hasHold {
	return self.kind == TIE_IOS_BUTTON_WHEEL || self.kind == TIE_IOS_BUTTON_TAP_HOLD;
}

- (CFTimeInterval)holdSeconds {
	return self.kind == TIE_IOS_BUTTON_WHEEL ? TIE_IOS_WHEEL_SECONDS : TIE_IOS_HOLD_SECONDS;
}

- (void)layoutHoldLayers {
	if (![self hasHold])
		return;
	if (!self.holdMark) {
		self.holdMark = [CAShapeLayer layer];
		self.holdMark.fillColor = UIColor.clearColor.CGColor;
		self.holdMark.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.75].CGColor;
		self.holdMark.lineWidth = 3.5;
		self.holdMark.lineCap = kCALineCapRound;
		[self.layer addSublayer:self.holdMark];
		self.holdRing = [CAShapeLayer layer];
		self.holdRing.fillColor = UIColor.clearColor.CGColor;
		self.holdRing.strokeColor = [UIColor colorWithRed:1.0 green:0.8 blue:0.3 alpha:0.95].CGColor;
		self.holdRing.lineWidth = 3.0;
		self.holdRing.strokeEnd = 0.0;
		self.holdRing.hidden = YES;
		[self.layer addSublayer:self.holdRing];
	}
	const CGRect bounds = self.bounds;
	const CGFloat radius = MIN(bounds.size.width, bounds.size.height) * 0.5;
	/* The lower-right quarter of the outline's right-hand curve. */
	const CGPoint corner = CGPointMake(CGRectGetMaxX(bounds) - radius, CGRectGetMaxY(bounds) - radius);
	self.holdMark.path = [UIBezierPath bezierPathWithArcCenter:corner
														radius:radius - 0.75
													startAngle:M_PI * 0.12
													  endAngle:M_PI * 0.38
													 clockwise:YES]
							 .CGPath;
	self.holdRing.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(bounds, 1.5, 1.5)
													cornerRadius:radius - 1.5]
							 .CGPath;
}

/* Fill the ring over the hold time, or clear it. */
- (void)showHoldProgress:(BOOL)holding {
	if (!self.holdRing)
		return;
	[self.holdRing removeAllAnimations];
	self.holdRing.hidden = !holding;
	if (!holding)
		return;
	CABasicAnimation* fill = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
	fill.fromValue = @0.0;
	fill.toValue = @1.0;
	fill.duration = [self holdSeconds];
	fill.fillMode = kCAFillModeForwards;
	fill.removedOnCompletion = NO;
	[self.holdRing addAnimation:fill forKey:@"fill"];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5;
	[self layoutHoldLayers];
	_label.frame = CGRectInset(self.bounds, 4, 2);
	if (self.chevron) {
		/* The chevron to the right of the label; set its frame without its
		 * turn, which may be mid-animation. */
		const CGFloat size = MIN(12.0, self.bounds.size.height * 0.35);
		const CGFloat inset = self.bounds.size.height * 0.35;
		_label.frame = CGRectMake(inset * 0.6, 2, self.bounds.size.width - inset * 1.3 - size,
								  self.bounds.size.height - 4);
		self.chevron.bounds = CGRectMake(0, 0, size, size);
		self.chevron.center = CGPointMake(self.bounds.size.width - inset * 0.55 - size / 2, CGRectGetMidY(self.bounds));
	}
	_label.font = [UIFont boldSystemFontOfSize:MAX(9.0, MIN(self.bounds.size.height * 0.28, 20.0))];
}

- (void)setHeld:(BOOL)held {
	_held = held;
	self.backgroundColor = [self.tint colorWithAlphaComponent:held ? 0.55 : 0.18];
}

/* A group toggle shows whether its group is open. */
- (void)setOpen:(BOOL)open {
	_open = open;
	[self restBorder];
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

/* Wheel choices that are not input actions: saving to or loading a
 * checkpoint slot, and saving to the slot used last. */
enum {
	TIE_IOS_CHOICE_SAVE = TIE_INPUT_ACTION_COUNT + 1,
	TIE_IOS_CHOICE_LOAD = TIE_IOS_CHOICE_SAVE + TIE_QUICKSAVE_SLOTS,
	TIE_IOS_CHOICE_SAVE_LAST = TIE_IOS_CHOICE_LOAD + TIE_QUICKSAVE_SLOTS,
};

static NSString* const TieIosCheckpointSlotKey = @"TieIosCheckpointSlot";

static int TieIos_LastCheckpointSlot(void) {
	const NSInteger slot = [[NSUserDefaults standardUserDefaults] integerForKey:TieIosCheckpointSlotKey];
	return slot >= 1 && slot <= TIE_QUICKSAVE_SLOTS ? (int)slot : 1;
}

static void TieIos_Tap(TieInputAction action) {
	const int choice = (int)action;
	if (choice == TIE_IOS_CHOICE_SAVE_LAST) {
		TieQuickSave_RequestSave(TieIos_LastCheckpointSlot());
		return;
	}
	if (choice >= TIE_IOS_CHOICE_SAVE && choice < TIE_IOS_CHOICE_SAVE_LAST) {
		const bool save = choice < TIE_IOS_CHOICE_LOAD;
		const int slot = choice - (save ? TIE_IOS_CHOICE_SAVE : TIE_IOS_CHOICE_LOAD) + 1;
		[[NSUserDefaults standardUserDefaults] setInteger:slot forKey:TieIosCheckpointSlotKey];
		if (save)
			TieQuickSave_RequestSave(slot);
		else
			TieQuickSave_RequestLoad(slot);
		return;
	}
	TieInputActions_DispatchController(action, true);
	TieInputActions_DispatchController(action, false);
}

- (void)press:(BOOL)down {
	if (down == self.held)
		return;
	self.held = down;
	[self showHoldProgress:down && [self hasHold]];
	if (down && [self hasHold])
		TieIos_PrepareHaptics();
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
		case TIE_IOS_BUTTON_WHEEL:
			if (down) {
				self.pressTime = CACurrentMediaTime();
				self.wheelOpen = NO;
			} else if (self.wheelOpen) {
				const NSInteger choice = [self.wheel committed];
				[self.wheel dismiss];
				self.wheelOpen = NO;
				if (choice >= 0 && (NSUInteger)choice < self.choiceTitles.count) {
					[ios_haptic_medium impactOccurred];
					TieIos_Tap(self.choiceActions[choice]);
				}
			} else {
				TieIos_Tap(self.action);
			}
			break;
		case TIE_IOS_BUTTON_TAP_HOLD:
			/* The hold fires from -tick:; a release before then is a tap. */
			if (down) {
				self.pressTime = CACurrentMediaTime();
				self.holdFired = NO;
			} else if (!self.holdFired) {
				TieIos_Tap(self.action);
			}
			[self restBorder];
			break;
		case TIE_IOS_BUTTON_REPEAT:
			self.nextRepeat = CACurrentMediaTime() + 0.35;
			/* fall through */
		case TIE_IOS_BUTTON_ACTION:
			TieInputActions_DispatchController(self.action, down);
			break;
	}
}

- (void)openWheel {
	if (self.wheelOpen || !self.wheel)
		return;
	self.wheelOpen = YES;
	[self showHoldProgress:NO];
	[ios_haptic_light impactOccurred];
	[self.wheel showFrom:[self.superview convertPoint:self.center toView:self.wheel]
				  finger:self.lastPoint
				  titles:self.choiceTitles
			   dangerous:self.dangerousChoices ? self.dangerousChoices : [NSIndexSet indexSet]
				disabled:self.disabledChoices ? self.disabledChoices() : [NSIndexSet indexSet]];
}

/* Once per frame: repeats, holds and wheels. */
- (void)tick:(CFTimeInterval)now {
	if (!self.held)
		return;
	if (self.kind == TIE_IOS_BUTTON_WHEEL && now - self.pressTime >= TIE_IOS_WHEEL_SECONDS)
		[self openWheel];
	if (self.wheelOpen)
		[self.wheel tick:now];
	if (self.kind == TIE_IOS_BUTTON_TAP_HOLD && !self.holdFired && now - self.pressTime >= TIE_IOS_HOLD_SECONDS) {
		self.holdFired = YES;
		[ios_haptic_notify notificationOccurred:UINotificationFeedbackTypeSuccess];
		[self showHoldProgress:NO];
		TieIos_Tap(self.holdAction);
		self.layer.borderColor = UIColor.whiteColor.CGColor;
	} else if (self.kind == TIE_IOS_BUTTON_REPEAT && now >= self.nextRepeat) {
		TieInputActions_DispatchController(self.action, false);
		TieInputActions_DispatchController(self.action, true);
		/* About a held desktop key's repeat rate. */
		self.nextRepeat = now + 0.04;
	}
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	ios_controller_in_use = false;
	self.lastPoint = [touches.anyObject locationInView:self.wheel];
	[self press:YES];
}

/* A wheel opens early when the finger slides off the button. */
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	if (self.kind != TIE_IOS_BUTTON_WHEEL)
		return;
	UITouch* touch = touches.anyObject;
	self.lastPoint = [touch locationInView:self.wheel];
	if (!self.wheelOpen && !CGRectContainsPoint(CGRectInset(self.bounds, -8, -8), [touch locationInView:self]))
		[self openWheel];
	if (self.wheelOpen)
		[self.wheel track:self.lastPoint];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	[self press:NO];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
	if (self.wheelOpen) {
		[self.wheel dismiss];
		self.wheel.selection = -1;
	}
	[self press:NO];
}

- (void)dealloc {
	free(_choiceActions);
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
		UIColor* flight = TieIos_CategoryColor(TIE_IOS_CATEGORY_FLIGHT);
		self.layer.borderWidth = 1.5;
		self.layer.borderColor = [flight colorWithAlphaComponent:0.8].CGColor;
		self.backgroundColor = [flight colorWithAlphaComponent:0.12];
		self.clipsToBounds = YES;
		_fill = [CALayer layer];
		_fill.backgroundColor = [flight colorWithAlphaComponent:0.4].CGColor;
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
/* The in-flight map: drag rotates or pans, pinch zooms. */
@property(nonatomic) BOOL map;
@property(nonatomic, strong) NSArray<TieTouchButton*>* mapRightButtons;
@property(nonatomic, strong) NSArray<TieTouchButton*>* mapLeftButtons;
/* The zoom a pinch holds: +1 in, -1 out, 0 none. */
@property(nonatomic) int pinchZoom;
@property(nonatomic, strong) TieTouchButton* pauseButton;
@property(nonatomic, strong) TieTouchButton* skipButton;
@property(nonatomic, strong) TieTouchButton* gyroButton;
@property(nonatomic, strong) TieChoiceWheel* wheel;
/* A short notice under the top row, such as a checkpoint's outcome. */
@property(nonatomic, strong) UILabel* toast;
/* The game picture as a fraction of the overlay's width; the buttons go in
 * the bars beside it. */
@property(nonatomic) CGFloat gameX;
@property(nonatomic) CGFloat gameWidth;
@property(nonatomic, strong) NSArray<TieTouchButton*>* buttons;
@property(nonatomic, strong) NSArray<TieTouchButton*>* leftButtons;
@property(nonatomic, strong) NSArray<TieTouchButton*>* rightButtons;
@property(nonatomic, strong) NSArray<TieTouchButton*>* topButtons;
@property(nonatomic, strong) NSArray<TieTouchGroup*>* groups;
/* MENU at the top center: its panel holds the game, info, view, wingman,
 * mission and checkpoint controls; INFO and VIEW open below it. */
@property(nonatomic, strong) TieTouchGroup* menuGroup;
/* The strip behind MENU's line, which stretches out from the center. */
@property(nonatomic, strong) UIView* menuBackdrop;
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

- (TieTouchButton*)wheelButton:(NSString*)title
						  tap:(TieInputAction)tap
					   titles:(NSArray<NSString*>*)titles
					  actions:(const TieInputAction*)actions {
	TieTouchButton* button = [[TieTouchButton alloc] initWithTitle:title
															action:tap
															  kind:TIE_IOS_BUTTON_WHEEL
															 place:TIE_IOS_PLACE_FLIGHT];
	button.choiceTitles = titles;
	button.choiceActions = malloc(titles.count * sizeof *actions);
	memcpy(button.choiceActions, actions, titles.count * sizeof *actions);
	button.wheel = self.wheel;
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
		_wheel = [[TieChoiceWheel alloc] initWithFrame:self.bounds];

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
		/* Gyro aiming, on or off; remembered between launches. */
		_gyroButton = [[TieTouchButton alloc] initWithTitle:@"GYRO"
													 action:TIE_INPUT_ACTION_NONE
													   kind:TIE_IOS_BUTTON_TOGGLE
													  place:TIE_IOS_PLACE_FLIGHT];
		__weak TieTouchButton* weak_gyro = _gyroButton;
		_gyroButton.toggle = ^{
			TieIos_SetGyro(!ios_gyro_on);
			[weak_gyro setOpen:ios_gyro_on];
		};
		TieIos_SetGyro([[NSUserDefaults standardUserDefaults] boolForKey:TieIosGyroKey]);
		[_gyroButton setOpen:ios_gyro_on];
		/* Left bar, one column down the outer edge; the throttle beside it. */
		_leftButtons = @[ escape, keyboard, _groups[0].toggle, _groups[1].toggle, _gyroButton ];
		/* Right bar, two to a row from the top, with FIRE below them. TGT
		 * takes the next target on a tap; held, its wheel picks the rest. */
		static const TieInputAction target_actions[] = {
			TIE_INPUT_ACTION_TARGET_NEAREST_FIGHTER_OR_MINE,
			TIE_INPUT_ACTION_TARGET_MY_ATTACKER,
			TIE_INPUT_ACTION_TARGET_ATTACKER_CHAIN,
			TIE_INPUT_ACTION_TARGET_NEWEST_CRAFT,
			/* The target viewer ('z'): the target from outside, with its
			 * name and weapons; again for the cockpit. */
			TIE_INPUT_ACTION_TOGGLE_THREAT_DISPLAY,
			TIE_INPUT_ACTION_TARGET_COMPONENT_NEXT,
			TIE_INPUT_ACTION_TARGET_COMPONENT_PREV,
			TIE_INPUT_ACTION_TARGET_CLEAR,
			TIE_INPUT_ACTION_TARGET_PREV,
		};
		_rightButtons = @[
			TieIos_RepeatButton(@"THR+", TIE_INPUT_ACTION_THROTTLE_UP),
			TieIos_RepeatButton(@"THR−", TIE_INPUT_ACTION_THROTTLE_DOWN),
			TieIos_Button(@"WPN", TIE_INPUT_ACTION_CYCLE_WEAPON_GROUP),
			TieIos_Button(@"LINK", TIE_INPUT_ACTION_CYCLE_WEAPON_FIRING_MODE),
			TieIos_Button(@"MATCH", TIE_INPUT_ACTION_MATCH_SPEED),
			TieIos_Button(@"ROLL", TIE_INPUT_ACTION_TARGET_ROLL_THROTTLE_MODIFIER),
			/* The map takes the same targeting keys. */
			[self wheelButton:@"TGT"
						  tap:TIE_INPUT_ACTION_TARGET_NEXT
					   titles:@[ @"NEAR", @"ATKR", @"CHAIN", @"NEWEST", @"VIEW", @"COMP ▶", @"COMP ◀", @"CLEAR", @"PREV" ]
					  actions:target_actions],
		];
		_rightButtons.lastObject.place = TIE_IOS_PLACE_FLIGHT | TIE_IOS_PLACE_MAP;
		/* The map screen. Its zoom is the joystick's first two buttons, held;
		 * Space switches the top and side views, 'c' centers on the target,
		 * h, i, n and w cycle which craft are shown, and the arrow keys turn
		 * the info pages. */
		static const TieInputAction show_actions[] = {
			TIE_INPUT_ACTION_HYPERSPACE,                /* 'h': hostile */
			TIE_INPUT_ACTION_TOGGLE_COMPONENT_TRACKING, /* 'i': Imperial */
			TIE_INPUT_ACTION_TOGGLE_SLAM,               /* 'n': neutral */
			TIE_INPUT_ACTION_CYCLE_WEAPON_GROUP,        /* 'w': warheads */
		};
		TieTouchButton* show = [self wheelButton:@"SHOW"
											 tap:TIE_INPUT_ACTION_NONE
										  titles:@[ @"HOSTILE", @"IMPERIAL", @"NEUTRAL", @"WARHEADS" ]
										 actions:show_actions];
		_mapRightButtons = @[
			TieIos_Button(@"ZOOM +", TIE_INPUT_ACTION_FIRE_WEAPON),
			TieIos_Button(@"ZOOM −", TIE_INPUT_ACTION_TARGET_ROLL_THROTTLE_MODIFIER),
			TieIos_Button(@"TOP /\nSIDE", TIE_INPUT_ACTION_CONFIRM),
			TieIos_Button(@"CENTER", TIE_INPUT_ACTION_RECORDER_TOGGLE),
			show,
		];
		_mapLeftButtons = @[
			TieIos_Button(@"◀ INFO", TIE_INPUT_ACTION_ROLL_LEFT_INFO_PREVIOUS),
			TieIos_Button(@"INFO ▶", TIE_INPUT_ACTION_ROLL_RIGHT_INFO_NEXT),
		];
		for (TieTouchButton* button in [_mapRightButtons arrayByAddingObjectsFromArray:_mapLeftButtons])
			button.place = TIE_IOS_PLACE_MAP;
		/* The look views, each placed in the direction it looks: clockwise
		 * from straight up. */
		static const TieInputAction look_actions[] = {
			TIE_INPUT_ACTION_VIEW_STRAIGHT_UP,  TIE_INPUT_ACTION_VIEW_RIGHT_FORWARD, TIE_INPUT_ACTION_VIEW_RIGHT_WING,
			TIE_INPUT_ACTION_VIEW_RIGHT_SHOULDER, TIE_INPUT_ACTION_VIEW_REAR,        TIE_INPUT_ACTION_VIEW_LEFT_SHOULDER,
			TIE_INPUT_ACTION_VIEW_LEFT_WING,    TIE_INPUT_ACTION_VIEW_LEFT_FORWARD,
		};
		/* Under MENU: PAUSE and OK, the INFO and VIEW submenus (one open at a
		 * time), and the wingman, mission and checkpoint wheels. */
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
							 /* Forward on a tap; held, the views all around. */
							 [self wheelButton:@"LOOK"
										   tap:TIE_INPUT_ACTION_VIEW_FORWARD
										titles:@[ @"UP", @"R FWD", @"RIGHT", @"R SHLDR", @"REAR", @"L SHLDR", @"LEFT",
												  @"L FWD" ]
									   actions:look_actions],
						 ]],
		];
		for (TieTouchGroup* group in submenus)
			group.submenu = YES;
		_groups = [_groups arrayByAddingObjectsFromArray:submenus];
		_pauseButton = TieIos_Button(@"PAUSE", TIE_INPUT_ACTION_PAUSE);
		/* Wingman orders: the WING screen on a tap; held, every order. */
		static const TieInputAction command_actions[] = {
			TIE_INPUT_ACTION_COMM_ASSIGN_TARGET,    TIE_INPUT_ACTION_COMM_COVER_ME,
			TIE_INPUT_ACTION_COMM_EVADE,            TIE_INPUT_ACTION_COMM_IGNORE_TARGET,
			TIE_INPUT_ACTION_COMM_STOP_AND_WAIT,    TIE_INPUT_ACTION_COMM_CONTINUE_MISSION,
			TIE_INPUT_ACTION_COMM_HEAD_HOME,        TIE_INPUT_ACTION_COMM_REPORT_ORDERS,
			TIE_INPUT_ACTION_COMM_REQUEST_RESUPPLY, TIE_INPUT_ACTION_COMM_REINFORCEMENTS,
		};
		TieTouchButton* command = [self wheelButton:@"CMD"
												tap:TIE_INPUT_ACTION_INFO_WINGMAN_COMMANDS
											 titles:@[ @"ATTACK", @"COVER", @"EVADE", @"IGNORE", @"WAIT", @"GO ON", @"HOME",
													   @"REPORT", @"RESUPPLY", @"REINF" ]
											actions:command_actions];
		/* Time compression on a tap; held, the rest of the mission, with
		 * ejecting and ending it only after resting on them. */
		static const TieInputAction mission_actions[] = {
			TIE_INPUT_ACTION_CYCLE_TIME_ACCELERATION, TIE_INPUT_ACTION_HYPERSPACE,
			TIE_INPUT_ACTION_RECORDER_TOGGLE,         TIE_INPUT_ACTION_EJECT,
			TIE_INPUT_ACTION_END_MISSION,
		};
		TieTouchButton* mission = [self wheelButton:@"MISSION"
												tap:TIE_INPUT_ACTION_CYCLE_TIME_ACCELERATION
											 titles:@[ @"TIME ×", @"HYPER", @"REC", @"EJECT", @"END" ]
											actions:mission_actions];
		mission.dangerousChoices = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(3, 2)];
		/* Checkpoints: a tap saves to the slot used last; held, saving to
		 * slots 1-3 across the top, loading them below in the same columns.
		 * Loading only after resting on it; an empty slot is dimmed. */
		static const TieInputAction checkpoint_actions[] = {
			(TieInputAction)(TIE_IOS_CHOICE_SAVE + 1), (TieInputAction)(TIE_IOS_CHOICE_SAVE + 2),
			(TieInputAction)(TIE_IOS_CHOICE_LOAD + 2), (TieInputAction)(TIE_IOS_CHOICE_LOAD + 1),
			(TieInputAction)(TIE_IOS_CHOICE_LOAD + 0), (TieInputAction)(TIE_IOS_CHOICE_SAVE + 0),
		};
		TieTouchButton* checkpoint = [self wheelButton:@"CHKPT"
												   tap:(TieInputAction)TIE_IOS_CHOICE_SAVE_LAST
												titles:@[ @"SAVE 2", @"SAVE 3", @"LOAD 3", @"LOAD 2", @"LOAD 1", @"SAVE 1" ]
											   actions:checkpoint_actions];
		checkpoint.dangerousChoices = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(2, 3)];
		checkpoint.disabledChoices = ^NSIndexSet* {
			NSMutableIndexSet* empty = [NSMutableIndexSet indexSet];
			/* Wheel positions 4, 3 and 2 load slots 1, 2 and 3. */
			for (int slot = 1; slot <= TIE_QUICKSAVE_SLOTS; ++slot)
				if (!TieQuickSave_HasCheckpoint(slot))
					[empty addIndex:5 - slot];
			return empty;
		};
		_menuGroup = [self groupWithTitle:@"MENU"
									  key:@"TieIosMenuOpen"
								  buttons:@[
									  _pauseButton,
									  TieIos_Button(@"OK", TIE_INPUT_ACTION_CONFIRM),
									  submenus[0].toggle,
									  submenus[1].toggle,
									  command,
									  mission,
									  checkpoint,
								  ]];
		[_menuGroup.toggle addChevron];
		[_menuGroup.toggle turnChevron:_menuGroup.open];
		__weak TieTouchOverlay* weak_overlay = self;
		_menuGroup.toggle.toggle = ^{
			[weak_overlay toggleMenu];
		};
		/* The menu panel itself is clear: its strip is a view that can
		 * stretch on its own, and MENU sits on top of both. */
		_menuBackdrop = [[UIView alloc] initWithFrame:CGRectZero];
		_menuBackdrop.backgroundColor = _menuGroup.panel.backgroundColor;
		_menuBackdrop.layer.cornerRadius = _menuGroup.panel.layer.cornerRadius;
		_menuBackdrop.userInteractionEnabled = NO;
		_menuGroup.panel.backgroundColor = UIColor.clearColor;
		[_menuGroup.panel insertSubview:_menuBackdrop atIndex:0];
		/* Its panel goes under the submenus' panels. */
		NSMutableArray<TieTouchGroup*>* groups = [_groups mutableCopy];
		[groups insertObject:_menuGroup atIndex:groups.count - submenus.count];
		_groups = groups;
		/* While paused, RESUME takes MENU's place. */
		TieTouchButton* resume = TieIos_Button(@"RESUME", TIE_INPUT_ACTION_PAUSE);
		resume.place = TIE_IOS_PLACE_PAUSED;
		_topButtons = @[ _menuGroup.toggle, resume ];
		_fireButton = TieIos_Button(@"FIRE", TIE_INPUT_ACTION_FIRE_WEAPON);
		NSMutableArray<TieTouchButton*>* all = [NSMutableArray array];
		[all addObjectsFromArray:_leftButtons];
		[all addObjectsFromArray:_rightButtons];
		[all addObjectsFromArray:_topButtons];
		[all addObject:_fireButton];
		[all addObject:_skipButton];
		[all addObjectsFromArray:_mapRightButtons];
		[all addObjectsFromArray:_mapLeftButtons];
		for (TieTouchButton* button in all)
			[self addSubview:button];
		for (TieTouchGroup* group in _groups) {
			[self addSubview:group.panel];
			[all addObjectsFromArray:group.buttons];
		}
		_buttons = all;
		for (TieTouchButton* button in _topButtons)
			[self bringSubviewToFront:button];
		_throttle = [[TieThrottleSlider alloc] initWithFrame:CGRectZero];
		[self addSubview:_throttle];
		[self colorButtons];
		[self addSubview:_wheel];
		_toast = [[UILabel alloc] initWithFrame:CGRectZero];
		_toast.textAlignment = NSTextAlignmentCenter;
		_toast.font = [UIFont boldSystemFontOfSize:15.0];
		_toast.textColor = UIColor.whiteColor;
		_toast.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
		_toast.layer.cornerRadius = 14.0;
		_toast.clipsToBounds = YES;
		_toast.alpha = 0.0;
		_toast.userInteractionEnabled = NO;
		[self addSubview:_toast];


		_stickBase = [CAShapeLayer layer];
		_stickBase.fillColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
		_stickBase.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
		_stickBase.lineWidth = 1.5;
		_stickKnob = [CAShapeLayer layer];
		_stickKnob.fillColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
		[self.layer addSublayer:_stickBase];
		[self.layer addSublayer:_stickKnob];
		/* A pinch on the map zooms it. */
		UIPinchGestureRecognizer* pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self
																				   action:@selector(pinch:)];
		pinch.delegate = (id<UIGestureRecognizerDelegate>)self;
		[self addGestureRecognizer:pinch];
		/* Two fingers dragged on the map pan it. */
		UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
																			  action:@selector(panMap:)];
		pan.minimumNumberOfTouches = 2;
		pan.maximumNumberOfTouches = 2;
		pan.delegate = (id<UIGestureRecognizerDelegate>)self;
		[self addGestureRecognizer:pan];
		_flight = YES;
		[self setFlight:NO paused:NO map:NO];
	}
	return self;
}

/* Every button not named here is a game control, in gray. */
- (void)colorButtons {
	NSDictionary<NSString*, NSNumber*>* categories = @{
		@"FIRE" : @(TIE_IOS_CATEGORY_WEAPONS),
		@"WPN" : @(TIE_IOS_CATEGORY_WEAPONS),
		@"LINK" : @(TIE_IOS_CATEGORY_WEAPONS),
		@"TGT" : @(TIE_IOS_CATEGORY_TARGETING),
		@"MEM" : @(TIE_IOS_CATEGORY_TARGETING),
		@"THR+" : @(TIE_IOS_CATEGORY_FLIGHT),
		@"THR−" : @(TIE_IOS_CATEGORY_FLIGHT),
		@"MATCH" : @(TIE_IOS_CATEGORY_FLIGHT),
		@"ROLL" : @(TIE_IOS_CATEGORY_FLIGHT),
		@"GYRO" : @(TIE_IOS_CATEGORY_FLIGHT),
		@"PWR" : @(TIE_IOS_CATEGORY_POWER),
		@"CMD" : @(TIE_IOS_CATEGORY_INFO),
	};
	for (TieTouchButton* button in [self.mapRightButtons arrayByAddingObjectsFromArray:self.mapLeftButtons])
		[button setCategory:TIE_IOS_CATEGORY_INFO];
	for (TieTouchButton* button in self.buttons) {
		NSNumber* category = categories[button.label.text];
		if (category)
			[button setCategory:(TieIosCategory)category.integerValue];
	}
	/* A group's buttons take its toggle's color: power, the target
	 * memories, and teal for the INFO, VIEW and CMD submenus. */
	for (TieTouchGroup* group in self.groups) {
		/* The MENU panel holds controls of several kinds, colored above. */
		if (group == self.menuGroup)
			continue;
		if (group.submenu)
			[group.toggle setCategory:TIE_IOS_CATEGORY_INFO];
		const TieIosCategory category = group.submenu ? TIE_IOS_CATEGORY_INFO
							  : [group.toggle.label.text isEqualToString:@"PWR"] ? TIE_IOS_CATEGORY_POWER
																			: TIE_IOS_CATEGORY_TARGETING;
		for (TieTouchButton* button in group.buttons)
			[button setCategory:category];
	}
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

/* Two columns from the top; an odd last button spans both. */
static void TieIos_LayoutPairs(NSArray<TieTouchButton*>* buttons, CGFloat x, CGFloat y, CGFloat cell,
							   CGFloat gap) {
	for (NSUInteger index = 0; index < buttons.count; ++index) {
		const bool span = index + 1 == buttons.count && index % 2 == 0;
		buttons[index].frame = CGRectMake(x + (index % 2) * (cell + gap), y + (index / 2) * (cell + gap),
										  span ? cell * 2 + gap : cell, cell);
	}
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
		if (group.submenu || group == self.menuGroup)
			continue;
		const NSUInteger rows = (group.buttons.count + 1) / 2;
		const CGSize panel = CGSizeMake(column_width + gap * 2, rows * (cell + gap) + gap);
		CGFloat y = CGRectGetMinY(group.toggle.frame) - gap;
		y = MAX(top, MIN(y, CGRectGetMaxY(area) - gap - panel.height));
		group.panel.frame = CGRectMake(CGRectGetMaxX(self.throttle.frame) + gap, y, panel.width, panel.height);
		TieIos_LayoutPairs(group.buttons, gap, gap, cell, gap);
	}

	TieIos_LayoutPairs(self.rightButtons, right_x, top, cell, gap);
	/* The map's buttons fill the rows above TGT and the left bar's free
	 * slots. */
	TieIos_LayoutPairs(self.mapRightButtons, right_x, top, cell, gap);
	for (NSUInteger index = 0; index < self.mapLeftButtons.count; ++index)
		self.mapLeftButtons[index].frame = self.leftButtons[2 + index].frame;
	const CGFloat fire_top = top + right_rows * (cell + gap);
	const CGFloat fire = MIN(column_width, CGRectGetMaxY(area) - gap - fire_top);
	self.fireButton.frame = CGRectMake(right_x + (column_width - fire) / 2, fire_top, fire, fire);

	/* MENU at the top center, always. Open, its buttons sit on the same
	 * line either side of it, the first half to its left; a submenu opens
	 * as a row below, under its toggle. */
	const CGFloat row_height = MAX(28.0, MIN(36.0, area.size.height * 0.08));
	const CGFloat menu_width = 84.0;
	const NSUInteger menu_count = self.menuGroup.buttons.count;
	const NSUInteger left_count = menu_count / 2;
	const CGFloat row_width =
		MIN(80.0, (game.size.width * 0.94 - menu_width - gap * (menu_count + 1)) / menu_count);
	const CGRect menu = CGRectMake(CGRectGetMidX(game) - menu_width / 2, top, menu_width, row_height);
	for (TieTouchButton* button in self.topButtons)
		button.frame = menu;
	const CGFloat left_edge = CGRectGetMinX(menu) - gap - left_count * (row_width + gap);
	const CGFloat right_edge = CGRectGetMaxX(menu) + gap + (menu_count - left_count) * (row_width + gap);
	self.menuGroup.panel.frame = CGRectMake(left_edge, top - gap, right_edge - left_edge, row_height + gap * 2);
	self.menuBackdrop.frame = self.menuGroup.panel.bounds;
	for (NSUInteger index = 0; index < menu_count; ++index) {
		const CGFloat x = index < left_count ? gap + index * (row_width + gap)
											 : CGRectGetMaxX(menu) - left_edge + gap +
												   (index - left_count) * (row_width + gap);
		self.menuGroup.buttons[index].frame = CGRectMake(x, gap, row_width, row_height);
	}
	for (TieTouchGroup* group in self.groups) {
		if (!group.submenu)
			continue;
		const NSUInteger count = group.buttons.count;
		const CGSize panel = CGSizeMake(count * (row_width + gap) + gap, row_height + gap * 2);
		const CGRect toggle = [group.toggle.superview convertRect:group.toggle.frame toView:self];
		CGFloat x = CGRectGetMidX(toggle) - panel.width / 2;
		x = MAX(CGRectGetMinX(game) + gap, MIN(x, CGRectGetMaxX(game) - gap - panel.width));
		group.panel.frame =
			CGRectMake(x, CGRectGetMaxY(self.menuGroup.panel.frame) + gap, panel.width, panel.height);
		for (NSUInteger index = 0; index < count; ++index)
			group.buttons[index].frame =
				CGRectMake(gap + index * (row_width + gap), gap, row_width, row_height);
	}
}

- (void)showToast:(NSString*)text {
	self.toast.text = text;
	const CGSize fit = [self.toast sizeThatFits:CGSizeMake(self.bounds.size.width, 28.0)];
	const CGRect game = [self gameRect];
	self.toast.frame = CGRectMake(CGRectGetMidX(game) - (fit.width + 32.0) / 2,
								  self.safeAreaInsets.top + 52.0, fit.width + 32.0, 28.0);
	[self bringSubviewToFront:self.toast];
	[self.toast.layer removeAllAnimations];
	self.toast.alpha = 1.0;
	[UIView animateWithDuration:0.4
						  delay:1.6
						options:UIViewAnimationOptionBeginFromCurrentState
					 animations:^{
						 self.toast.alpha = 0.0;
					 }
					 completion:nil];
}

- (void)updateVisibility {
	for (TieTouchButton* button in self.buttons) {
		BOOL visible = (button.place & [self screen]) != 0;
		for (TieTouchGroup* group in self.groups)
			if ([group.buttons containsObject:button])
				visible = visible && group.open;
		if (!visible && button.held)
			[button press:NO];
		button.hidden = !visible;
	}
	for (TieTouchGroup* group in self.groups) {
		group.panel.hidden = group.toggle.hidden || !group.open;
		[group.toggle setOpen:group.open];
	}
	self.throttle.hidden = !self.flight;
}

- (TieIosButtonPlace)screen {
	return self.flight ? TIE_IOS_PLACE_FLIGHT
		   : self.paused ? TIE_IOS_PLACE_PAUSED
		   : self.map	 ? TIE_IOS_PLACE_MAP
						 : TIE_IOS_PLACE_MENUS;
}

/* The flight stick works in the cockpit and on the map. */
- (BOOL)stickActive {
	return self.flight || self.map;
}

- (void)setFlight:(BOOL)flight paused:(BOOL)paused map:(BOOL)map {
	if (flight == _flight && paused == _paused && map == _map)
		return;
	_flight = flight;
	_paused = paused;
	_map = map;
	[self setPinchZoom:0];
	[self updateVisibility];
	if (![self stickActive])
		[self endStick];
}

/* MENU's buttons fan out from behind it to either side, nearest first,
 * as the strip behind them stretches from the center; closing draws them
 * back in. */
- (void)toggleMenu {
	TieTouchGroup* menu = self.menuGroup;
	const BOOL open = !menu.open;
	[[NSUserDefaults standardUserDefaults] setBool:open forKey:menu.key];
	[self layoutIfNeeded];
	UIView* panel = menu.panel;
	const CGPoint hub = [self convertPoint:menu.toggle.center toView:panel];
	const CGFloat strip = menu.toggle.bounds.size.width / MAX(1.0, panel.bounds.size.width);
	/* Each button tucked behind MENU, small and clear. */
	CGAffineTransform (^tucked)(TieTouchButton*) = ^CGAffineTransform(TieTouchButton* button) {
		const CGAffineTransform shrink = CGAffineTransformMakeScale(0.3, 0.3);
		return CGAffineTransformConcat(shrink, CGAffineTransformMakeTranslation(hub.x - button.center.x,
																				  hub.y - button.center.y));
	};
	NSArray<TieTouchButton*>* buttons = menu.buttons;
	/* Nearest to MENU first: its distance in buttons. */
	NSUInteger (^rank)(NSUInteger) = ^NSUInteger(NSUInteger index) {
		const NSUInteger left = buttons.count / 2;
		return index < left ? left - 1 - index : index - left;
	};
	if (open) {
		menu.open = YES;
		[self updateVisibility];
		self.menuBackdrop.transform = CGAffineTransformMakeScale(strip, 1.0);
		for (TieTouchButton* button in buttons) {
			button.transform = tucked(button);
			button.alpha = 0.0;
		}
		[UIView animateWithDuration:0.22
						 animations:^{
							 self.menuBackdrop.transform = CGAffineTransformIdentity;
							 [menu.toggle turnChevron:YES];
						 }];
		for (NSUInteger index = 0; index < buttons.count; ++index)
			[UIView animateWithDuration:0.32
								  delay:0.03 * rank(index)
				 usingSpringWithDamping:0.75
				  initialSpringVelocity:0.0
								options:UIViewAnimationOptionBeginFromCurrentState
							 animations:^{
								 buttons[index].transform = CGAffineTransformIdentity;
								 buttons[index].alpha = 1.0;
							 }
							 completion:nil];
		return;
	}
	NSMutableArray<UIView*>* rows = [NSMutableArray array];
	for (TieTouchGroup* group in self.groups)
		if (group.submenu && !group.panel.hidden)
			[rows addObject:group.panel];
	[UIView animateWithDuration:0.2
		animations:^{
			self.menuBackdrop.transform = CGAffineTransformMakeScale(strip, 1.0);
			for (TieTouchButton* button in buttons) {
				button.transform = tucked(button);
				button.alpha = 0.0;
			}
			for (UIView* row in rows)
				row.alpha = 0.0;
			[menu.toggle turnChevron:NO];
		}
		completion:^(BOOL finished) {
			(void)finished;
			menu.open = NO;
			[self updateVisibility];
			self.menuBackdrop.transform = CGAffineTransformIdentity;
			for (TieTouchButton* button in buttons) {
				button.transform = CGAffineTransformIdentity;
				button.alpha = 1.0;
			}
			for (UIView* row in rows)
				row.alpha = 1.0;
		}];
}

/* Hold the map's zoom in (+1), out (-1) or neither, as its zoom buttons do. */
- (void)setPinchZoom:(int)zoom {
	if (zoom == _pinchZoom)
		return;
	if (_pinchZoom)
		TieInputActions_DispatchController(_pinchZoom > 0 ? TIE_INPUT_ACTION_FIRE_WEAPON
														  : TIE_INPUT_ACTION_TARGET_ROLL_THROTTLE_MODIFIER,
										   false);
	_pinchZoom = zoom;
	if (zoom)
		TieInputActions_DispatchController(zoom > 0 ? TIE_INPUT_ACTION_FIRE_WEAPON
													: TIE_INPUT_ACTION_TARGET_ROLL_THROTTLE_MODIFIER,
										   true);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)recognizer shouldReceiveTouch:(UITouch*)touch {
	return self.map && touch.view == self;
}

/* Pinch and two-finger pan together: zoom and pan at once. */
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)recognizer
	shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
	return YES;
}

/* The map pans a fixed step per number key (the numeric keypad's
 * directions), as when the key was held on DOS. Each 14 points the fingers
 * travel sends one step, moving the map with them: the camera goes the
 * other way. */
- (void)panMap:(UIPanGestureRecognizer*)recognizer {
	static const CGFloat step = 14.0;
	/* Camera direction, clockwise from screen-right: the keypad keys. */
	static const TieInputAction keys[8] = {
		TIE_INPUT_ACTION_VIEW_RIGHT_WING,    /* '6' */
		TIE_INPUT_ACTION_VIEW_RIGHT_SHOULDER, /* '3' */
		TIE_INPUT_ACTION_VIEW_REAR,          /* '2' */
		TIE_INPUT_ACTION_VIEW_LEFT_SHOULDER,  /* '1' */
		TIE_INPUT_ACTION_VIEW_LEFT_WING,     /* '4' */
		TIE_INPUT_ACTION_VIEW_LEFT_FORWARD,  /* '7' */
		TIE_INPUT_ACTION_VIEW_FORWARD,       /* '8' */
		TIE_INPUT_ACTION_VIEW_RIGHT_FORWARD, /* '9' */
	};
	if (recognizer.state != UIGestureRecognizerStateBegan && recognizer.state != UIGestureRecognizerStateChanged)
		return;
	[self endStick];
	const CGPoint moved = [recognizer translationInView:self];
	if (hypot(moved.x, moved.y) < step)
		return;
	const double angle = atan2(-moved.y, -moved.x);
	const long sector = ((lround(angle / (M_PI / 4.0)) % 8) + 8) % 8;
	TieIos_Tap(keys[sector]);
	[recognizer setTranslation:CGPointZero inView:self];
}

/* Spreading the fingers zooms in, closing them zooms out, for as long as
 * they keep moving. */
- (void)pinch:(UIPinchGestureRecognizer*)recognizer {
	switch (recognizer.state) {
		case UIGestureRecognizerStateBegan:
		case UIGestureRecognizerStateChanged:
			[self endStick];
			[self setPinchZoom:recognizer.velocity > 0.2 ? 1 : recognizer.velocity < -0.2 ? -1 : 0];
			break;
		default:
			[self setPinchZoom:0];
			break;
	}
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

/* Outside flight and the map, the overlay passes every touch but its
 * buttons to SDL. */
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
	UIView* hit = [super hitTest:point withEvent:event];
	return hit == self && ![self stickActive] ? nil : hit;
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
		if (self.stickTouch || ![self stickActive])
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

/* A checkpoint's outcome: a notice and a buzz. */
static void TieIos_ReportQuickSave(void) {
	static uint32_t reported;
	uint32_t serial;
	int slot;
	const TieQuickSaveResult result = TieQuickSave_LastResult(&serial, &slot);
	if (serial == reported)
		return;
	reported = serial;
	NSString* text = nil;
	bool ok = false;
	switch (result) {
		case TIE_QUICKSAVE_SAVED:
			text = [NSString stringWithFormat:@"Saved to slot %d", slot];
			ok = true;
			break;
		case TIE_QUICKSAVE_LOADED:
			text = [NSString stringWithFormat:@"Loaded slot %d", slot];
			ok = true;
			break;
		case TIE_QUICKSAVE_NO_CHECKPOINT:
			text = [NSString stringWithFormat:@"Slot %d has no checkpoint for this mission", slot];
			break;
		case TIE_QUICKSAVE_UNAVAILABLE:
			text = @"Can't use checkpoints right now";
			break;
		case TIE_QUICKSAVE_FAILED:
		case TIE_QUICKSAVE_NONE:
			text = @"The checkpoint failed";
			break;
	}
	TieIos_PrepareHaptics();
	[ios_haptic_notify notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
	[ios_overlay showToast:text];
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
	const bool map = snapshot && snapshot->scene_kind == TIE_SCENE_FLIGHT &&
					 snapshot->flight_screen == TIE_FLIGHT_SCREEN_MAP && !TieSettings_Open();
	[ios_overlay setFlight:flight paused:paused map:map];
	const TiePresentationLayout* presentation = TiePresentation_Layout();
	if (presentation && presentation->frame.width > 0)
		[ios_overlay setGameX:(CGFloat)presentation->modern.x / presentation->frame.width
						width:(CGFloat)presentation->modern.width / presentation->frame.width];
	[ios_overlay tickButtons];
	TieIos_ReportQuickSave();
	TieIos_UpdateGyro(flight, ios_overlay.window.windowScene.interfaceOrientation);
	TieIos_ApplyStick();
	TieIos_MapTouchThrottle();
	uint16_t throttle;
	if (flight && TieUserTiming_PlayerThrottle(&throttle))
		[ios_overlay followThrottle:(CGFloat)throttle / UINT16_MAX];
	[ios_overlay.superview bringSubviewToFront:ios_overlay];
}

void TieIos_Shutdown(void) {
	SDL_RemoveEventWatch(TieIos_WatchEvent, NULL);
	[ios_motion stopDeviceMotionUpdates];
	[ios_overlay removeFromSuperview];
	ios_overlay = nil;
	TieIos_DetachGamepad();
}
