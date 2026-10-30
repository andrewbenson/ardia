#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdlib.h>

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

@interface ArdiaCoreProfile : NSObject
@property(copy) NSString *path;
@property BOOL offTheRecord;
@end
@implementation ArdiaCoreProfile
@end

typedef void (^ArdiaCoreResult)(NSDictionary *);
@interface ArdiaCoreServices : NSObject
+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args completion:(ArdiaCoreResult)completion;
+ (void)downloadCommand:(NSString *)command id:(NSString *)downloadId;
@end

static int profileCalls = 0;
static int engineCalls = 0;
static NSMutableArray *received;
static NSMutableArray *symbols;
namespace ardiacore_host {
BOOL IsIncognito(NSString *) { return NO; }
NSArray<ArdiaCoreProfile *> *LoadedProfiles() { return @[]; }
NSString *ProfileName(ArdiaCoreProfile *) { return @""; }
NSString *OriginalProfileName(NSString *profile) { return profile; }
void WithProfile(NSString *name, void (^done)(ArdiaCoreProfile *)) {
  if (![name isEqualToString:@"fixture-profile-id"]) abort();
  profileCalls++;
  ArdiaCoreProfile *profile = [ArdiaCoreProfile new];
  profile.path = @"fixture-profile";
  done(profile);
}
}

void FakeEngine(const char *profile, const char *args, void (*reply)(void *, const char *), void *context) {
  engineCalls++;
  NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:[@(args) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  [received addObject:@{ @"profile": @(profile), @"args": parsed }];
  reply(context, "{\"ok\":true}");
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
    DownloadProfiles()[@"download-42"] = @"fixture-profile-id";
    NSMutableArray *results = [NSMutableArray array];
    for (NSNumber *mode in @[ @YES, @NO ]) {
      ArdiaCoreHost.safeMode = mode.boolValue;
      for (NSString *command in @[ @"remove", @"cancel" ]) {
        profileCalls = engineCalls = 0;
        [received removeAllObjects];
        [symbols removeAllObjects];
        [ArdiaCoreServices downloadCommand:command id:@"download-42"];
        [results addObject:@{ @"safe": mode, @"command": command, @"engineCalls": @(engineCalls), @"profileCalls": @(profileCalls),
                             @"symbols": [symbols copy], @"received": [received copy] }];
      }
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
  }
}
