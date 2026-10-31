#import "SolaraCoreTabParking.h"

#import "SolaraCoreEarlyWindow.h"

#import <objc/runtime.h>

namespace {

constexpr int64_t kReloadHoldSeconds = 30;
constexpr int64_t kLaunchTabSeconds = 30;
constexpr int64_t kLinkTabsBackstopSeconds = 300;
constexpr NSUInteger kMaxLinkTabs = 4;

const char kHolderKey = 0;

NSMutableDictionary<NSString *, SolaraCoreTab *> *Parked() {
  static NSMutableDictionary *parked = [NSMutableDictionary dictionary];
  return parked;
}

NSMutableDictionary<NSString *, NSNumber *> *ReloadHolds() {
  static NSMutableDictionary *holds = [NSMutableDictionary dictionary];
  return holds;
}
NSUInteger gReloads;

NSMutableSet<NSString *> *ClosedLaunch() {
  static NSMutableSet<NSString *> *keys = [NSMutableSet set];
  return keys;
}

NSMutableSet<NSString *> *ClosedLaunchWithWindow() {
  static NSMutableSet<NSString *> *keys = [NSMutableSet set];
  return keys;
}

SolaraCoreTab *gLaunchTab;
NSString *gLaunchKey;
NSString *gLaunchURL;
NSString *gLaunchProfile;
BOOL gLaunchClaimed;

NSMutableDictionary<NSNumber *, SolaraCoreTab *> *LinkTabs() {
  static NSMutableDictionary *tabs = [NSMutableDictionary dictionary];
  return tabs;
}
NSMutableDictionary<NSNumber *, NSString *> *LinkURLs() {
  static NSMutableDictionary *urls = [NSMutableDictionary dictionary];
  return urls;
}
NSMutableArray<NSString *> *DismissedLinks() {
  static NSMutableArray *urls = [NSMutableArray array];
  return urls;
}
NSMutableSet<NSString *> *DismissedLinkMarks() {
  static NSMutableSet *marks = [NSMutableSet set];
  return marks;
}
NSString *gLinkProfile;
BOOL gLinkTabsStarted;
BOOL gLinkTabsRouted;

NSView *ParkingView() {
  static NSView *view = [[NSView alloc] initWithFrame:NSZeroRect];
  return view;
}

void CloseNow(SolaraCoreTab *tab) {
  if ([tab respondsToSelector:@selector(closeNow)]) [tab closeNow];
  else [tab close];
}

void CloseOpenTab(SolaraCoreTab *tab) {
  if (!tab || tab.closed) return;
  CloseNow(tab);
}

void ExpireLaunchTabUnlessShown(SolaraCoreTab *tab) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kLaunchTabSeconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (gLaunchTab != tab) return;
    if ([SolaraCoreEarlyWindow holdsPage:tab]) return ExpireLaunchTabUnlessShown(tab);
    [SolaraCoreTabParking claimLaunchTab:@"" url:@"" profile:@""];
  });
}

void CloseLinkTabs() {
  NSArray<SolaraCoreTab *> *left = LinkTabs().allValues;
  [LinkTabs() removeAllObjects];
  [LinkURLs() removeAllObjects];
  for (SolaraCoreTab *tab in left) {
    [SolaraCoreEarlyWindow dropPage:tab];
    CloseOpenTab(tab);
  }
}

}

@implementation SolaraCoreTabParking

+ (void)park:(SolaraCoreTab *)tab forKey:(NSString *)key {
  [ParkingView() addSubview:tab.view];
  Parked()[key] = tab;
}

+ (SolaraCoreTab *)parkedTabForKey:(NSString *)key {
  return Parked()[key];
}

+ (void)unpark:(NSString *)key {
  [Parked() removeObjectForKey:key];
}

+ (void)tookTransfer:(NSString *)key {
  [ReloadHolds() removeObjectForKey:key];
}

+ (void)releaseTransfer:(NSString *)key {
  [ClosedLaunch() removeObject:key];
  [ClosedLaunchWithWindow() removeObject:key];
  SolaraCoreTab *tab = Parked()[key];
  if (!tab) return;
  [Parked() removeObjectForKey:key];
  CloseNow(tab);
}

+ (BOOL)launchWasClosed:(NSString *)key {
  SolaraCoreTab *tab = Parked()[key];
  id<SolaraCoreParkedPageHolder> held = tab ? objc_getAssociatedObject(tab, &kHolderKey) : nil;
  if (held && (tab.closed || held.closedByChrome)) {
    [Parked() removeObjectForKey:key];
    [ClosedLaunch() addObject:key];
    if (held.closedWithWindow) [ClosedLaunchWithWindow() addObject:key];
  }
  return [ClosedLaunch() containsObject:key];
}

+ (BOOL)launchClosedWithWindow:(NSString *)key {
  return [ClosedLaunchWithWindow() containsObject:key];
}

+ (void)rehomeFromWindow:(SolaraCoreWindowController *)closing {
  for (SolaraCoreTab *tab in Parked().allValues) {
    if (tab.closed || [SolaraCoreWindowController holding:tab] != closing || !tab.profile) continue;
    SolaraCoreWindowController *keeper = [SolaraCoreWindowController strayWindowForProfile:tab.profile];
    keeper.hostChanges++;
    closing.hostChanges++;
    [keeper.coreWindow adoptTab:tab];
    closing.hostChanges--;
    keeper.hostChanges--;
  }
}

+ (void)keepOffscreen:(SolaraCoreTab *)tab holder:(id<SolaraCoreParkedPageHolder>)holder {
  [ParkingView() addSubview:tab.view];
  objc_setAssociatedObject(tab, &kHolderKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  tab.delegate = holder;
}

+ (id<SolaraCoreParkedPageHolder>)takeHolderOfTab:(SolaraCoreTab *)tab {
  id<SolaraCoreParkedPageHolder> holder = objc_getAssociatedObject(tab, &kHolderKey);
  objc_setAssociatedObject(tab, &kHolderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return holder;
}

+ (void)holdAcrossReload:(NSDictionary<NSString *, SolaraCoreTab *> *)tabs expired:(void (^)(NSString *, SolaraCoreTab *))expired {
  NSNumber *reload = @(++gReloads);
  NSDictionary<NSString *, SolaraCoreTab *> *held = [tabs copy];
  for (NSString *key in held) ReloadHolds()[key] = reload;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kReloadHoldSeconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [held enumerateKeysAndObjectsUsingBlock:^(NSString *key, SolaraCoreTab *tab, BOOL *) {
      if (![ReloadHolds()[key] isEqual:reload]) return;
      [ReloadHolds() removeObjectForKey:key];
      expired(key, tab);
      if (Parked()[key] != tab) return;
      [Parked() removeObjectForKey:key];
      CloseNow(tab);
    }];
  });
}

+ (SolaraCoreTab *)launchTab {
  return gLaunchTab;
}

+ (void)holdLaunchTab:(NSString *)key url:(NSString *)url profile:(NSString *)profile opening:(SolaraCoreTab * (^)(void))open {
  if (gLaunchTab || gLaunchClaimed || !key.length) return;
  SolaraCoreTab *tab = open();
  if (!tab) return;
  gLaunchTab = tab;
  gLaunchKey = [key copy];
  gLaunchURL = [url copy];
  gLaunchProfile = [(profile ?: @"") copy];
  ExpireLaunchTabUnlessShown(tab);
}

+ (void)claimLaunchTab:(NSString *)transferKey url:(NSString *)url profile:(NSString *)profile {
  NSString *key = [transferKey copy], *claimed = [url copy], *name = [profile copy];
  void (^claim)(void) = ^{
    SolaraCoreTab *tab = gLaunchTab;
    gLaunchClaimed = YES;
    const BOOL same = tab && key.length && [gLaunchKey isEqualToString:key] && [gLaunchURL isEqualToString:claimed] &&
                      [gLaunchProfile isEqualToString:name ?: @""] && !Parked()[key];
    gLaunchTab = nil;
    gLaunchKey = gLaunchURL = gLaunchProfile = nil;
    if (!same) [SolaraCoreEarlyWindow dropPage:tab];
    if (!same) return CloseOpenTab(tab);
    Parked()[key] = tab;
  };
  if (NSThread.isMainThread) claim();
  else dispatch_async(dispatch_get_main_queue(), claim);
}

+ (SolaraCoreTab *)firstLinkTab {
  return LinkTabs()[@0];
}

+ (void)holdLinkTabs:(NSArray<NSString *> *)urls profile:(NSString *)profile opening:(SolaraCoreTab * (^)(NSString *))open {
  if (gLinkTabsStarted) return;
  gLinkTabsStarted = YES;
  gLinkProfile = [profile copy] ?: @"";
  NSUInteger index = 0;
  for (NSString *url in urls) {
    if (index >= kMaxLinkTabs) break;
    if (SolaraCoreTab *tab = open(url)) {
      LinkTabs()[@(index)] = tab;
      LinkURLs()[@(index)] = [url copy];
    }
    index++;
  }
  if (!LinkTabs().count) return;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kLinkTabsBackstopSeconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    CloseLinkTabs();
  });
}

+ (NSString *)linkMarkForTab:(SolaraCoreTab *)tab {
  for (NSNumber *index in LinkTabs())
    if (LinkTabs()[index] == tab && LinkURLs()[index]) return [NSString stringWithFormat:@"link:%@", index];
  return nil;
}

+ (void)dismissLinkTab:(SolaraCoreTab *)tab {
  for (NSNumber *index in LinkTabs().allKeys) {
    if (LinkTabs()[index] != tab) continue;
    [LinkTabs() removeObjectForKey:index];
    if (NSString *url = LinkURLs()[index]) [DismissedLinks() addObject:url];
    [DismissedLinkMarks() addObject:[NSString stringWithFormat:@"link:%@", index]];
    [LinkURLs() removeObjectForKey:index];
    [SolaraCoreEarlyWindow dropPage:tab];
    CloseOpenTab(tab);
    return;
  }
}

+ (BOOL)takeDismissedLinkMark:(NSString *)mark {
  if (![DismissedLinkMarks() containsObject:mark]) return NO;
  [DismissedLinkMarks() removeObject:mark];
  return YES;
}

+ (BOOL)linkTabsRouted {
  return gLinkTabsRouted;
}

+ (void)noteLittleWindowOpening {
  gLinkTabsRouted = YES;
}

+ (NSString *)soleLinkURL {
  return LinkTabs().count == 1 && LinkURLs().count == 1 && LinkTabs()[@0] ? LinkURLs()[@0] : nil;
}

+ (NSString *)linkProfile {
  return gLinkTabsStarted ? gLinkProfile : nil;
}

+ (NSDictionary<NSString *, id> *)routeLinkTabs:(NSArray<NSString *> *)urls {
  gLinkTabsRouted = YES;
  NSMutableArray *marks = [NSMutableArray array];
  NSMutableSet<NSNumber *> *used = [NSMutableSet set];
  NSMutableArray<NSNumber *> *dismissed = [NSMutableArray array];
  BOOL any = NO;
  for (NSString *url in urls) {
    id mark = NSNull.null;
    if (const NSUInteger at = [DismissedLinks() indexOfObject:url]; at != NSNotFound) {
      [DismissedLinks() removeObjectAtIndex:at];
      [dismissed addObject:@(marks.count)];
      [marks addObject:mark];
      continue;
    }
    for (NSNumber *index in [LinkURLs().allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      if ([used containsObject:index] || ![LinkURLs()[index] isEqualToString:url] || !LinkTabs()[index]) continue;
      [used addObject:index];
      mark = [NSString stringWithFormat:@"link:%@", index];
      any = YES;
      break;
    }
    [marks addObject:mark];
  }
  if (!any) return dismissed.count ? @{@"dismissed" : dismissed} : @{};
  for (NSNumber *index in used) [LinkURLs() removeObjectForKey:index];
  return @{@"profile" : gLinkProfile ?: @"", @"adoptIds" : marks, @"dismissed" : dismissed};
}

+ (SolaraCoreTab *)parkLinkTab:(NSString *)mark forKey:(NSString *)key {
  NSNumber *index = @([[mark substringFromIndex:5] integerValue]);
  SolaraCoreTab *tab = LinkTabs()[index];
  if (!tab || !key.length || Parked()[key]) return nil;
  [LinkTabs() removeObjectForKey:index];
  Parked()[key] = tab;
  return tab;
}

+ (void)discardTab:(SolaraCoreTab *)tab forKey:(NSString *)key {
  if (Parked()[key] == tab) [Parked() removeObjectForKey:key];
  [SolaraCoreEarlyWindow dropPage:tab];
  CloseOpenTab(tab);
}

@end
