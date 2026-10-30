#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdlib.h>

static int profileCalls = 0;
static int engineCalls = 0;
static int pictureCalls = 0;
static NSMutableArray *received;
static NSMutableArray *symbols;

@interface ArdiaCoreHost : NSObject
@property(class) BOOL safeMode;
@property(class, readonly) BOOL isStarted;
@end
@implementation ArdiaCoreHost
static BOOL safe = NO;
+ (BOOL)safeMode { return safe; }
+ (void)setSafeMode:(BOOL)value { safe = value; }
+ (BOOL)isStarted { return YES; }
@end

@interface ArdiaCoreEarlyWindow : NSObject
+ (void)forgetPictures;
@end
@implementation ArdiaCoreEarlyWindow
+ (void)forgetPictures { pictureCalls++; }
@end

@interface ArdiaCoreProfile : NSObject
@property(copy) NSString *path;
@property BOOL offTheRecord;
- (void)clearBrowsingData:(NSArray<NSString *> *)types since:(NSDate *)since completion:(void (^)(void))completion;
@end
@implementation ArdiaCoreProfile
- (void)clearBrowsingData:(NSArray<NSString *> *)types since:(NSDate *)since completion:(void (^)(void))completion {
  engineCalls++;
  [received addObject:@{ @"profile": self.path, @"types": types, @"since": @(since.timeIntervalSince1970) }];
  completion();
}
@end

typedef void (^ArdiaCoreResult)(NSDictionary *);
@interface ArdiaCoreServices : NSObject
+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args completion:(ArdiaCoreResult)completion;
+ (void)clearBrowsingData:(NSString *)profile types:(NSArray<NSString *> *)types since:(double)sinceMs completion:(void (^)(void))completion;
+ (void)clearSiteData:(NSString *)profile origin:(NSString *)origin completion:(ArdiaCoreResult)completion;
@end

namespace ardiacore_host {
BOOL IsIncognito(NSString *) { return NO; }
NSArray<ArdiaCoreProfile *> *LoadedProfiles() { return @[]; }
NSString *ProfileName(ArdiaCoreProfile *) { return @""; }
NSString *OriginalProfileName(NSString *profile) { return profile; }
ArdiaCoreProfile *LoadedProfile(NSString *name) {
  if (![name isEqualToString:@"fixture-profile-id"]) abort();
  profileCalls++;
  ArdiaCoreProfile *profile = [ArdiaCoreProfile new];
  profile.path = @"fixture-profile";
  return profile;
}
void WithProfile(NSString *name, void (^done)(ArdiaCoreProfile *)) { done(LoadedProfile(name)); }
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
      ArdiaCoreHost.safeMode = mode.boolValue;
      for (NSString *path in @[ @"browsing", @"browsingCache", @"site", @"bridge" ]) {
        profileCalls = engineCalls = pictureCalls = 0;
        [received removeAllObjects];
        [symbols removeAllObjects];
        __block int callbacks = 0;
        __block NSDictionary *reply = @{};
        BOOL history = [path isEqualToString:@"browsing"];
        if ([path hasPrefix:@"browsing"]) {
          [ArdiaCoreServices clearBrowsingData:@"fixture-profile-id" types:history ? @[ @"history", @"siteData", @"cache" ] : @[ @"cache" ] since:123000 completion:^{ callbacks++; }];
        } else if ([path isEqualToString:@"site"]) {
          [ArdiaCoreServices clearSiteData:@"fixture-profile-id" origin:@"https://example.test" completion:^(NSDictionary *result) { callbacks++; reply = result; }];
        } else {
          [ArdiaCoreServices call:@"ac_browsing_data_clear" profile:@"fixture-profile-id" args:@{ @"types": @[ @"cache" ] } completion:^(NSDictionary *result) { callbacks++; reply = result; }];
        }
        [results addObject:@{ @"safe": mode, @"path": [path hasPrefix:@"browsing"] ? @"browsing" : path, @"history": @(history), @"engineCalls": @(engineCalls), @"profileCalls": @(profileCalls),
                             @"pictureCalls": @(pictureCalls), @"callbacks": @(callbacks), @"reply": reply, @"symbols": [symbols copy], @"received": [received copy] }];
      }
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
  }
}
