#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdlib.h>

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

@interface SolaraCoreProfile : NSObject
@property(copy) NSString *path;
@property BOOL offTheRecord;
@end
@implementation SolaraCoreProfile
@end

static int profileCalls = 0;
static int engineCalls = 0;
static int symbolCalls = 0;
static NSMutableArray *received;
static NSMutableArray *symbols;
namespace solaracore_host {
BOOL IsIncognito(NSString *) { return NO; }
NSArray<SolaraCoreProfile *> *LoadedProfiles() { return @[]; }
NSString *ProfileName(SolaraCoreProfile *) { return @""; }
NSString *OriginalProfileName(NSString *profile) { return profile; }
void WithProfile(NSString *, void (^done)(SolaraCoreProfile *)) {
  profileCalls++;
  SolaraCoreProfile *profile = [SolaraCoreProfile new];
  profile.path = @"fixture-profile";
  done(profile);
}
}

void FakeEngine(const char *profile, const char *args, void (*reply)(void *, const char *), void *context) {
  engineCalls++;
  [received addObject:@{ @"profile": @(profile), @"args": @(args) }];
  reply(context, "{\"ok\":true}");
}
void *FakeSymbolLookup(void *, const char *name) {
  symbolCalls++;
  [symbols addObject:@(name)];
  return (void *)&FakeEngine;
}
#define dlsym FakeSymbolLookup

__PRODUCTION__

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    received = [NSMutableArray array];
    symbols = [NSMutableArray array];
    NSMutableArray *results = [NSMutableArray array];
    NSString *name = @(argv[1]);
    NSString *input = argc > 2 ? @(argv[2]) : @"{\"marker\":42}";
    for (NSNumber *mode in @[ @YES, @NO ]) {
      SolaraCoreHost.safeMode = mode.boolValue;
      for (NSNumber *secret in @[ @NO, @YES ]) {
        profileCalls = engineCalls = symbolCalls = 0;
        [received removeAllObjects];
        [symbols removeAllObjects];
        __block int callbacks = 0;
        __block NSDictionary *reply;
        void (^done)(NSString *) = ^(NSString *json) {
          callbacks++;
          reply = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        };
        NSMutableData *args = [[input dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [args appendBytes:"" length:1];
        if (secret.boolValue) [SolaraCoreEngineBridge callWithSecret:name profile:@"1" args:args completion:done];
        else [SolaraCoreEngineBridge call:name profile:@"1" args:input completion:done];
        BOOL wiped = YES;
        for (NSUInteger i = 0; i < args.length; i++) if (((const unsigned char *)args.bytes)[i]) wiped = NO;
        [results addObject:@{ @"safe": mode, @"secret": secret, @"reply": reply ?: @{}, @"callbacks": @(callbacks),
                             @"profileCalls": @(profileCalls), @"engineCalls": @(engineCalls), @"symbolCalls": @(symbolCalls),
                             @"received": [received copy], @"symbols": [symbols copy], @"wiped": @(wiped) }];
      }
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
  }
}
