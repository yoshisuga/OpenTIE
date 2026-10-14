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

typedef enum TieIosButtonPlace {
	TIE_IOS_PLACE_ALWAYS, /* menus and flight */
	TIE_IOS_PLACE_FLIGHT, /* the cockpit only */
	TIE_IOS_PLACE_MENUS,  /* everywhere but the cockpit */
} TieIosButtonPlace;

static const CFTimeInterval TIE_IOS_HOLD_SECONDS = 0.5;
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
	self.radius = MIN(110.0, size.height * 0.3);
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
			[self wheelButton:@"TGT"
						  tap:TIE_INPUT_ACTION_TARGET_NEXT
					   titles:@[ @"NEAR", @"ATKR", @"CHAIN", @"NEWEST", @"VIEW", @"COMP ▶", @"COMP ◀", @"CLEAR", @"PREV" ]
					  actions:target_actions],
		];
		/* The look views, each placed in the direction it looks: clockwise
		 * from straight up. */
		static const TieInputAction look_actions[] = {
			TIE_INPUT_ACTION_VIEW_STRAIGHT_UP,  TIE_INPUT_ACTION_VIEW_RIGHT_FORWARD, TIE_INPUT_ACTION_VIEW_RIGHT_WING,
			TIE_INPUT_ACTION_VIEW_RIGHT_SHOULDER, TIE_INPUT_ACTION_VIEW_REAR,        TIE_INPUT_ACTION_VIEW_LEFT_SHOULDER,
			TIE_INPUT_ACTION_VIEW_LEFT_WING,    TIE_INPUT_ACTION_VIEW_LEFT_FORWARD,
		};
		/* The top row, between the scopes: PAUSE and OK, submenus that open
		 * below it one at a time, and the mission and checkpoint wheels. */
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
		_topButtons = @[
			_pauseButton,
			TieIos_Button(@"OK", TIE_INPUT_ACTION_CONFIRM),
			submenus[0].toggle,
			submenus[1].toggle,
			submenus[2].toggle,
			mission,
			checkpoint,
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
	const CGFloat row_width = MIN(80.0, (game.size.width * 0.7 - gap * (row_count - 1)) / row_count);
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
	[ios_overlay setFlight:flight paused:paused];
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
