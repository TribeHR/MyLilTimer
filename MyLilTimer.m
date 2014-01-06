//
//  MyLilTimer.m
//  TimerTest
//
//  Created by Jonathon Mah on 2014-01-01.
//  Copyright (c) 2014 Jonathon Mah. All rights reserved.
//

#import "MyLilTimer.h"

#import <objc/message.h>
#import <sys/sysctl.h>



static NSString *NSStringFromMyLilTimerBehavior(MyLilTimerBehavior b)
{
    switch (b) {
#define CASE_RETURN(x)  case x: return @#x
            CASE_RETURN(MyLilTimerBehaviorHourglass);
            CASE_RETURN(MyLilTimerBehaviorPauseOnSystemSleep);
            CASE_RETURN(MyLilTimerBehaviorObeySystemClockChanges);
#undef CASE_RETURN
    }
    return nil;
}

static BOOL isValidBehavior(MyLilTimerBehavior b)
{
    return (NSStringFromMyLilTimerBehavior(b) != nil);
}

static NSTimeInterval timeIntervalSinceBoot(void)
{
    // TODO: Potentially a race condition if the system clock changes between reading `bootTime` and `now`
    int status;

    struct timeval bootTime;
    status = sysctl((int[]){CTL_KERN, KERN_BOOTTIME}, 2,
                    &bootTime, &(size_t){sizeof(bootTime)},
                    NULL, 0);
    NSCAssert(status == 0, nil);

    struct timeval now;
    status = gettimeofday(&now, NULL);
    NSCAssert(status == 0, nil);

    struct timeval difference;
    timersub(&now, &bootTime, &difference);

    return (difference.tv_sec + difference.tv_usec * 1.e-6);
}

static void assertMainThread(void)
{
    NSCAssert([NSThread isMainThread], @"MyLilTimer does not currently support background threads.");
}


@interface MyLilTimer ()
@property (nonatomic, readwrite, getter = isValid) BOOL valid;
@end


@implementation MyLilTimer {
    id _target;
    SEL _action;

    NSTimeInterval _fireIntervalValue;
    NSSet *_runLoopModes;
    NSTimer *_nextCheckTimer;
}


#pragma mark NSObject

- (instancetype)init
{
    NSAssert(NO, @"Bad initializer, use %s", sel_getName(@selector(initWithBehavior:timeInterval:target:selector:userInfo:)));
    return nil;
}

- (void)dealloc
{
    [self invalidate];
}


#pragma mark MyLilTimer: API

+ (NSTimeInterval)timeIntervalValueForBehavior:(MyLilTimerBehavior)behavior
{
    NSParameterAssert(isValidBehavior(behavior));
    switch (behavior) {
        case MyLilTimerBehaviorHourglass:
            return timeIntervalSinceBoot();
        case MyLilTimerBehaviorPauseOnSystemSleep:
            // a.k.a. [NSProcessInfo processInfo].systemUptime
            // a.k.a. _CFGetSystemUptime()
            // a.k.a. mach_absolute_time() (in different units)
            return CACurrentMediaTime();
        case MyLilTimerBehaviorObeySystemClockChanges:
            return [NSDate timeIntervalSinceReferenceDate];
    }
}


- (instancetype)initWithBehavior:(MyLilTimerBehavior)behavior timeInterval:(NSTimeInterval)intervalSinceNow target:(id)target selector:(SEL)action userInfo:(id)userInfo
{
    if (!(self = [super init])) {
        return nil;
    }

    assertMainThread();
    NSParameterAssert(isValidBehavior(behavior));
    NSParameterAssert(target != nil);
    NSParameterAssert(action != NULL);

    // NSTimer behavior
    intervalSinceNow = MAX(0.1e-3, intervalSinceNow);

    _behavior = behavior;
    _target = target;
    _action = action;
    _userInfo = userInfo;

    _fireIntervalValue = [[self class] timeIntervalValueForBehavior:self.behavior] + intervalSinceNow;

    self.valid = YES;

    return self;
}

- (void)scheduleOnMainRunLoopForModes:(NSSet *)modes
{
    assertMainThread();
    if (_runLoopModes) {
        [NSException raise:NSInvalidArgumentException format:@"Timer can only be scheduled once"];
    }
    NSParameterAssert(modes.count > 0);
    _runLoopModes = [modes copy];

    NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
    UIApplication *app = [UIApplication sharedApplication];
    for (NSString *notificationName in [[self class] notificationNamesTriggeringRevalidation]) {
        [defaultCenter addObserver:self selector:@selector(checkExpirationAndRescheduleIfNeeded:) name:notificationName object:app];
    }

    [self checkExpirationAndRescheduleIfNeeded:self];
}

- (void)fire
{
    assertMainThread();
    if (!self.valid) {
        return;
    }

    ((void(*)(id, SEL, id))objc_msgSend)(_target, _action, self);
    //[_target performSelector:_action withObject:self];

    [self invalidate];
}

- (NSDate *)fireDate
{ return [NSDate dateWithTimeIntervalSinceNow:-self.timeSinceFireDate]; }

- (NSTimeInterval)timeSinceFireDate
{
    assertMainThread();
    return [[self class] timeIntervalValueForBehavior:self.behavior] - _fireIntervalValue;
}

- (void)setTolerance:(NSTimeInterval)tolerance
{
    _tolerance = tolerance;
    [self checkExpirationAndRescheduleIfNeeded:self];
}

- (void)invalidate
{
    assertMainThread();
    if (!self.valid) {
        return;
    }

    self.valid = NO;
    _target = nil;
    _userInfo = nil;

    if (!_runLoopModes) {
        return; // never scheduled
    }

    [_nextCheckTimer invalidate];
    _nextCheckTimer = nil;

    NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
    UIApplication *app = [UIApplication sharedApplication];
    for (NSString *notificationName in [[self class] notificationNamesTriggeringRevalidation]) {
        [defaultCenter removeObserver:self name:notificationName object:app];
    }
}


#pragma mark MyLilTimer: Private

+ (NSArray *)notificationNamesTriggeringRevalidation
{
    return @[
        UIApplicationSignificantTimeChangeNotification,
        UIApplicationWillEnterForegroundNotification,
#define USE_UNDOCUMENTED_NOTIFICATIONS 1
        /* Without these, timers will not be up-to-date when the application is resumed while
         * running in the background.
         * TODO: Is there another way to know when the app is resumed? Catch SIGCONT? */
#if USE_UNDOCUMENTED_NOTIFICATIONS
        @"UIApplicationResumedNotification",
        @"UIApplicationResumedEventsOnlyNotification",
#endif
    ];
}

/// Sender is notification, timer, or self
- (void)checkExpirationAndRescheduleIfNeeded:(id)sender
{
    assertMainThread();
    if (!self.valid || !_runLoopModes.count) {
        return;
    }

    // _nextCheckTimer may have the only strong reference to us; keep ourselves alive while it's invalidated
    __typeof(self) __attribute__((objc_precise_lifetime, unused)) strongSelf = self;

    [_nextCheckTimer invalidate];
    _nextCheckTimer = nil;

    NSDate *fireDate = self.fireDate;
    if (fireDate.timeIntervalSinceNow <= 0) {
        // Need to fire; do so in its own run loop pass so callback is run in a consistent execution environment.
        // No need to keep track of "waiting to fire" state; multiple calls are harmless.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self fire];
        });
        return;
    }

    _nextCheckTimer = [[NSTimer alloc] initWithFireDate:fireDate interval:0 target:self selector:_cmd userInfo:nil repeats:NO];
	_nextCheckTimer.tolerance = self.tolerance;

    NSAssert([NSRunLoop currentRunLoop] == [NSRunLoop mainRunLoop], @"MyLilTimer only supports the main run loop");
    NSRunLoop *runLoop = [NSRunLoop mainRunLoop];
    for (NSString *mode in _runLoopModes) {
        [runLoop addTimer:_nextCheckTimer forMode:mode];
    }
}


@end