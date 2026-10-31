#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

@interface CATransaction (ACMarkPrivate)
+ (void)addCommitHandler:(void (^)(void))block forPhase:(unsigned int)phase;
@end

static FILE *gOut;

static void Mark(NSString *key, NSInteger window) {
  fprintf(gOut, "{\"%s\":%.1f,\"window\":%ld}\n", key.UTF8String, NSDate.date.timeIntervalSince1970 * 1000, (long)window);
  fflush(gOut);
}

static void Signpost(const char *name, long window, double at) {
  fprintf(gOut, "{\"signpost\":\"%s\",\"at\":%.1f,\"window\":%ld}\n", name, at, window);
  fflush(gOut);
}

static BOOL HookSignposts(void) {
  void (*set)(void (*)(const char *, long, double)) = dlsym(RTLD_DEFAULT, "SolaraSignpostsSetObserver");
  if (!set) return NO;
  set(Signpost);
  return YES;
}

__attribute__((constructor)) static void Start(void) {
  const char *dir = getenv("SOLARA_DATA_DIR");
  if (!dir) return;
  if (![NSBundle.mainBundle.bundlePath hasSuffix:@".app"] || [NSBundle.mainBundle.bundlePath containsString:@"Helper"]) return;
  gOut = fopen([NSString stringWithFormat:@"%s/bench-marks.jsonl", dir].UTF8String, "a");
  if (!gOut) return;
  if (getenv("AC_BENCH_KEYLOG")) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
      double now = NSDate.date.timeIntervalSince1970 * 1000;
      fprintf(gOut, "{\"keydown\":%.1f,\"made\":%.1f,\"window\":%ld,\"char\":%d}\n", now,
              now - (NSProcessInfo.processInfo.systemUptime - event.timestamp) * 1000, (long)event.windowNumber, event.characters.length ? (int)[event.characters characterAtIndex:0] : 0);
      fflush(gOut);
      return event;
    }];
  }
  if (!HookSignposts()) {
    __block int tries = 0;
    CFRunLoopTimerRef retry = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0, ^(CFRunLoopTimerRef t) {
      if (HookSignposts() || ++tries >= 20) CFRunLoopTimerInvalidate(t);
    });
    CFRunLoopAddTimer(CFRunLoopGetMain(), retry, kCFRunLoopCommonModes);
  }
  [NSNotificationCenter.defaultCenter addObserverForName:@"RCTContentDidAppearNotification" object:nil queue:nil
                                              usingBlock:^(NSNotification *note) {
    if ([note.object isKindOfClass:NSView.class] && [NSStringFromClass([((NSView *)note.object).superview class]) hasSuffix:@"ShellView"]) return;
    NSInteger window = [note.object isKindOfClass:NSView.class] ? ((NSView *)note.object).window.windowNumber : 0;
    Mark(@"content", window);
    [CATransaction addCommitHandler:^{ Mark(@"committed", window); } forPhase:2];
  }];
}
