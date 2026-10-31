#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdlib.h>

static int profileCalls = 0;
static int engineCalls = 0;
static int pictureCalls = 0;
static NSMutableArray *received;
static NSMutableArray *symbols;

@interface SolaraCoreHost : NSObject
@property(class) BOOL safeMode;
@property(class, readonly) BOOL isStarted;
@end
@implementation SolaraCoreHost
static BOOL safe = NO;
+ (BOOL)safeMode { return safe; }
+ (void)setSafeMode:(BOOL)value { safe = value; }
+ (BOOL)isStarted { return YES; }
@end

@interface SolaraCoreEarlyWindow : NSObject
+ (void)forgetPictures;
@end
@implementation SolaraCoreEarlyWindow
+ (void)forgetPictures { pictureCalls++; }
@end

@interface SolaraCoreProfile : NSObject
@property(copy) NSString *path;
@property BOOL offTheRecord;
- (void)clearBrowsingData:(NSArray<NSString *> *)types since:(NSDate *)since completion:(void (^)(void))completion;
@end
@implementation SolaraCoreProfile
- (void)clearBrowsingData:(NSArray<NSString *> *)types since:(NSDate *)since completion:(void (^)(void))completion {
  engineCalls++;
  [received addObject:@{ @"profile": self.path, @"types": types, @"since": @(since.timeIntervalSince1970) }];
  completion();
}
@end

typedef void (^SolaraCoreResult)(NSDictionary *);
@interface SolaraCoreServices : NSObject
+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args completion:(SolaraCoreResult)completion;
+ (void)clearBrowsingData:(NSString *)profile types:(NSArray<NSString *> *)types since:(double)sinceMs completion:(void (^)(void))completion;
+ (void)clearSiteData:(NSString *)profile origin:(NSString *)origin completion:(SolaraCoreResult)completion;
@end

namespace solaracore_host {
BOOL IsIncognito(NSString *) { return NO; }
NSArray<SolaraCoreProfile *> *LoadedProfiles() { return @[]; }
NSString *ProfileName(SolaraCoreProfile *) { return @""; }
NSString *OriginalProfileName(NSString *profile) { return profile; }
SolaraCoreProfile *LoadedProfile(NSString *name) {
  if (![name isEqualToString:@"fixture-profile-id"]) abort();
  profileCalls++;
  SolaraCoreProfile *profile = [SolaraCoreProfile new];
  profile.path = @"fixture-profile";
  return profile;
}
void WithProfile(NSString *name, void (^done)(SolaraCoreProfile *)) { done(LoadedProfile(name)); }
}

void FakeEngine(const char *profile, const char *args, void (*reply)(void *, const char *), void *context) {
  engineCalls++;
  NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:[@(args) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  [received addObject:@{ @"profile": @(profile), @"args": parsed }];
  reply(context, "{\"cookies\":2,\"storage\":true}");
}
void *FakeSymbolLookup(void *, const char *name) {
  [symbols addObject:@(name)];
  return (void *)&FakeEngine;
}
#define dlsym FakeSymbolLookup

__PRODUCTION__

int main() {
  @autoreleasepool {
    received = [NSMutableArray array];
    symbols = [NSMutableArray array];
    NSMutableArray *results = [NSMutableArray array];
    for (NSNumber *mode in @[ @YES, @NO ]) {
      SolaraCoreHost.safeMode = mode.boolValue;
      for (NSString *path in @[ @"browsing", @"browsingCache", @"site", @"bridge" ]) {
        profileCalls = engineCalls = pictureCalls = 0;
        [received removeAllObjects];
        [symbols removeAllObjects];
        __block int callbacks = 0;
        __block NSDictionary *reply = @{};
        BOOL history = [path isEqualToString:@"browsing"];
        if ([path hasPrefix:@"browsing"]) {
          [SolaraCoreServices clearBrowsingData:@"fixture-profile-id" types:history ? @[ @"history", @"siteData", @"cache" ] : @[ @"cache" ] since:123000 completion:^{ callbacks++; }];
        } else if ([path isEqualToString:@"site"]) {
          [SolaraCoreServices clearSiteData:@"fixture-profile-id" origin:@"https://example.test" completion:^(NSDictionary *result) { callbacks++; reply = result; }];
        } else {
          [SolaraCoreServices call:@"ac_browsing_data_clear" profile:@"fixture-profile-id" args:@{ @"types": @[ @"cache" ] } completion:^(NSDictionary *result) { callbacks++; reply = result; }];
        }
        [results addObject:@{ @"safe": mode, @"path": [path hasPrefix:@"browsing"] ? @"browsing" : path, @"history": @(history), @"engineCalls": @(engineCalls), @"profileCalls": @(profileCalls),
                             @"pictureCalls": @(pictureCalls), @"callbacks": @(callbacks), @"reply": reply, @"symbols": [symbols copy], @"received": [received copy] }];
      }
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
  }
}
