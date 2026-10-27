#import "ArdiaCoreFieldTiming.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <React/RCTBridge.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTUIManager.h>
#import <React/RCTUIManagerUtils.h>
#import <os/lock.h>

#include <atomic>
#include <cmath>

@interface CATransaction (ACFieldTimingPrivate)
+ (void)addCommitHandler:(void (^)(void))block forPhase:(unsigned int)phase;
@end

namespace {

constexpr NSUInteger kMaxMarks = 512;
constexpr unsigned int kPostCommit = 2;

std::atomic<bool> gEnabled{false};
std::atomic<uintptr_t> gOwner{0};
std::atomic<double> gLastInputAt{0};
std::atomic<int> gLastInputKind{0};
os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
NSMutableArray<NSArray *> *gMarks;
id gInputMonitor;
id gPresentObserver;
__weak NSWindow *gLastInputWindow;

double EventTime(NSEvent *event) {
  return ACFieldNow() - (NSProcessInfo.processInfo.systemUptime - event.timestamp) * 1000;
}

void SetEnabled(bool enabled) {
  gEnabled = enabled;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (enabled && !gInputMonitor) {
      gInputMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp
                                                            handler:^NSEvent *(NSEvent *event) {
        gLastInputAt = EventTime(event);
        if (event.window) gLastInputWindow = event.window;
        gLastInputKind = event.type == NSEventTypeKeyDown ? 1 : 2;
        return event;
      }];
    } else if (!enabled && gInputMonitor) {
      [NSEvent removeMonitor:gInputMonitor];
      gInputMonitor = nil;
    }
    if (enabled && !gPresentObserver) {
      gPresentObserver = [NSNotificationCenter.defaultCenter addObserverForName:@"ACFieldMarkAtPresent" object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSArray *mark = [note.object isKindOfClass:NSArray.class] ? note.object : nil;
        if (mark.count == 2) ACFieldMarkAtPresent(mark[0], mark[1]);
      }];
    } else if (!enabled && gPresentObserver) {
      [NSNotificationCenter.defaultCenter removeObserver:gPresentObserver];
      gPresentObserver = nil;
    }
    ArdiaCoreWebViewsSetFieldTiming(gEnabled);
  });
  if (enabled) return;
  os_unfair_lock_lock(&gLock);
  [gMarks removeAllObjects];
  os_unfair_lock_unlock(&gLock);
}

}

BOOL ACFieldTimingEnabled(void) {
  return gEnabled;
}

double ACFieldNow(void) {
  return NSDate.date.timeIntervalSince1970 * 1000;
}

void ACFieldMark(NSString *key, NSString *kind, double at) {
  if (!gEnabled || !key.length || !std::isfinite(at)) return;
  NSArray *mark = @[ key, kind, @(round(at * 10) / 10) ];
  os_unfair_lock_lock(&gLock);
  if (!gMarks) gMarks = [NSMutableArray array];
  if (gMarks.count >= kMaxMarks) [gMarks removeObjectAtIndex:0];
  [gMarks addObject:mark];
  os_unfair_lock_unlock(&gLock);
}

void ACFieldMarkNow(NSString *key, NSString *kind) {
  if (gEnabled) ACFieldMark(key, kind, ACFieldNow());
}

void ACFieldMarkAtCommit(NSString *key, NSString *kind) {
  if (!gEnabled || !key.length) return;
  NSString *k = [key copy];
  if ([CATransaction respondsToSelector:@selector(addCommitHandler:forPhase:)])
    [CATransaction addCommitHandler:^{ ACFieldMark(k, kind, ACFieldNow()); } forPhase:kPostCommit];
  else
    ACFieldMark(k, kind, ACFieldNow());
}

@interface ACPresentedMark : NSObject
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, strong, nullable) CADisplayLink *link;
@end

@implementation ACPresentedMark

- (void)tick:(CADisplayLink *)link {
  ACFieldMark(self.key, [self.kind stringByAppendingString:@"Frame"], ACFieldNow() + (link.targetTimestamp - CACurrentMediaTime()) * 1000);
  [link invalidate];
  self.link = nil;
}

@end

void ACFieldMarkAtPresent(NSString *key, NSString *kind) {
  if (!gEnabled || !key.length) return;
  NSString *k = [key copy], *what = [kind copy];
  void (^arm)(void) = ^{
    NSWindow *window = gLastInputWindow ?: NSApp.keyWindow ?: NSApp.mainWindow;
    if (!window.contentView) return;
    ACPresentedMark *mark = [ACPresentedMark new];
    mark.key = k;
    mark.kind = what;
    mark.link = [window.contentView displayLinkWithTarget:mark selector:@selector(tick:)];
    [mark.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      [mark.link invalidate];
      mark.link = nil;
    });
  };
  if ([CATransaction respondsToSelector:@selector(addCommitHandler:forPhase:)])
    [CATransaction addCommitHandler:^{
      ACFieldMark(k, what, ACFieldNow());
      dispatch_async(dispatch_get_main_queue(), arm);
    } forPhase:kPostCommit];
  else
    ACFieldMark(k, what, ACFieldNow());
}

@interface ACFieldTimingModule : NSObject <RCTBridgeModule, RCTInvalidating>
@end

@implementation ACFieldTimingModule

@synthesize bridge = _bridge;

RCT_EXPORT_MODULE(ACFieldTiming)

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (dispatch_queue_t)methodQueue {
  return RCTGetUIManagerQueue();
}

RCT_EXPORT_METHOD(setEnabled : (BOOL)enabled) {
  gOwner = (uintptr_t)(__bridge void *)self;
  SetEnabled(enabled);
}

- (void)invalidate {
  uintptr_t me = (uintptr_t)(__bridge void *)self;
  if (gOwner.compare_exchange_strong(me, 0)) SetEnabled(false);
}

RCT_EXPORT_METHOD(markFrame : (NSString *)key kind : (NSString *)kind) {
  if (!gEnabled) return;
  NSString *k = [key copy], *what = [kind copy];
  [_bridge.uiManager addUIBlock:^(__unused RCTUIManager *manager, __unused NSDictionary *registry) {
    ACFieldMarkAtCommit(k, what);
  }];
}

RCT_EXPORT_METHOD(markPresented : (NSString *)key kind : (NSString *)kind) {
  if (!gEnabled) return;
  NSString *k = [key copy], *what = [kind copy];
  [_bridge.uiManager addUIBlock:^(__unused RCTUIManager *manager, __unused NSDictionary *registry) {
    ACFieldMarkAtPresent(k, what);
  }];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(lastInput) {
  return @[ @(round(gLastInputAt.load() * 10) / 10), @(gLastInputKind.load()) ];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(drain) {
  os_unfair_lock_lock(&gLock);
  NSArray *marks = gMarks.copy ?: @[];
  [gMarks removeAllObjects];
  os_unfair_lock_unlock(&gLock);
  return marks;
}

@end
