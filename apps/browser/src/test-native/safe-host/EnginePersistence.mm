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

static NSString *fixture;
static NSMutableArray *received;
namespace solaracore_host {
BOOL IsIncognito(NSString *) { return NO; }
NSArray<SolaraCoreProfile *> *LoadedProfiles() { return @[]; }
NSString *ProfileName(SolaraCoreProfile *) { return @"1"; }
NSString *OriginalProfileName(NSString *profile) { return profile; }
void WithProfile(NSString *, void (^done)(SolaraCoreProfile *)) {
  SolaraCoreProfile *profile = [SolaraCoreProfile new];
  profile.path = [fixture stringByAppendingPathComponent:@"Profile 1"];
  done(profile);
}
}

NSDictionary *FixtureRead(NSString *name) {
  NSData *data = [NSData dataWithContentsOfFile:[fixture stringByAppendingPathComponent:name]];
  return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : @{};
}
void FixtureWrite(NSString *name, NSDictionary *value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  NSCAssert([data writeToFile:[fixture stringByAppendingPathComponent:name] atomically:YES], @"fixture write failed");
}
NSString *LoginKey(NSDictionary *args) { return [NSString stringWithFormat:@"%@|%@", args[@"origin"], args[@"username"]]; }
NSString *FromHex(NSString *hex) {
  NSMutableData *data = [NSMutableData data];
  for (NSUInteger offset = 0; offset + 1 < hex.length; offset += 2) {
    unsigned int value;
    NSScanner *scanner = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(offset, 2)]];
    [scanner scanHexInt:&value];
    unsigned char byte = value;
    [data appendBytes:&byte length:1];
  }
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}
void FixtureCall(NSString *name, const char *profile, const char *json, void (*reply)(void *, const char *), void *context) {
  NSDictionary *args = [NSJSONSerialization JSONObjectWithData:[@(json ?: "{}") dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  [received addObject:@{ @"name": name, @"profile": @(profile), @"args": args ?: @{} }];
  NSDictionary *result = @{@"ok": @YES};
  if ([name hasPrefix:@"ac_passwords_"]) {
    NSMutableDictionary *passwords = [FixtureRead(@"Login Data") mutableCopy];
    NSString *key = LoginKey(args);
    if ([name isEqual:@"ac_passwords_add"]) {
      passwords[key] = @{ @"origin": args[@"origin"], @"username": args[@"username"], @"password": FromHex(args[@"passwordHex"]) };
      FixtureWrite(@"Login Data", passwords);
    } else if ([name isEqual:@"ac_passwords_update"]) {
      NSMutableDictionary *entry = [passwords[key] mutableCopy];
      [passwords removeObjectForKey:key];
      if (args[@"newUsername"]) entry[@"username"] = args[@"newUsername"];
      if (args[@"newPasswordHex"]) entry[@"password"] = FromHex(args[@"newPasswordHex"]);
      passwords[LoginKey(entry)] = entry;
      FixtureWrite(@"Login Data", passwords);
    } else if ([name isEqual:@"ac_passwords_remove"]) {
      [passwords removeObjectForKey:key];
      FixtureWrite(@"Login Data", passwords);
    } else if ([name isEqual:@"ac_passwords_reveal"]) {
      result = passwords[key] ?: @{};
    }
  } else if ([name isEqual:@"ac_bookmarks_apply"]) {
    NSMutableDictionary *bookmarks = [FixtureRead(@"Bookmarks") mutableCopy];
    for (NSDictionary *op in args[@"ops"]) {
      NSString *identifier = op[@"id"];
      if ([op[@"op"] isEqual:@"remove"]) [bookmarks removeObjectForKey:identifier];
      else {
        NSMutableDictionary *entry = [bookmarks[identifier] mutableCopy] ?: [NSMutableDictionary dictionary];
        [entry addEntriesFromDictionary:op];
        bookmarks[identifier] = entry;
      }
    }
    FixtureWrite(@"Bookmarks", bookmarks);
    result = @{ @"applied": @([args[@"ops"] count]), @"skipped": @0, @"invalid": @[] };
  } else if ([name isEqual:@"ac_history_delete_urls"]) {
    NSMutableDictionary *history = [FixtureRead(@"History") mutableCopy];
    for (NSString *url in args[@"urls"]) [history removeObjectForKey:url];
    FixtureWrite(@"History", history);
  } else if ([name isEqual:@"ac_history_import"]) {
    NSMutableDictionary *history = [FixtureRead(@"History") mutableCopy];
    for (NSDictionary *row in args[@"rows"]) history[row[@"u"]] = row;
    FixtureWrite(@"History", history);
  } else if ([name hasPrefix:@"ac_autofill_"]) {
    NSMutableDictionary *web = [FixtureRead(@"Web Data") mutableCopy];
    NSMutableDictionary *addresses = [web[@"addresses"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *cards = [web[@"cards"] mutableCopy] ?: [NSMutableDictionary dictionary];
    BOOL changed = NO;
    if ([name isEqual:@"ac_autofill_save_address"]) {
      NSDictionary *address = args[@"address"];
      addresses[address[@"id"]] = address;
      changed = YES;
    } else if ([name isEqual:@"ac_autofill_save_card"]) {
      NSMutableDictionary *card = [args[@"card"] mutableCopy];
      card[@"number"] = FromHex(args[@"numberHex"]);
      cards[card[@"id"]] = card;
      changed = YES;
    } else if ([name isEqual:@"ac_autofill_remove"]) {
      [addresses removeObjectForKey:args[@"id"]];
      [cards removeObjectForKey:args[@"id"]];
      changed = YES;
    } else if ([name isEqual:@"ac_autofill_import"]) {
      for (NSDictionary *address in args[@"addresses"]) addresses[address[@"id"] ?: @"imported-address"] = address;
      for (NSDictionary *card in args[@"cards"]) cards[card[@"id"] ?: @"imported-card"] = card;
      changed = YES;
      result = @{ @"addresses": @([args[@"addresses"] count]), @"cards": @([args[@"cards"] count]) };
    } else if ([name isEqual:@"ac_autofill_addresses"]) {
      result = @{ @"addresses": addresses.allValues };
    } else if ([name isEqual:@"ac_autofill_cards"]) {
      result = @{ @"cards": cards.allValues };
    }
    if (changed) FixtureWrite(@"Web Data", @{ @"addresses": addresses, @"cards": cards });
  } else if ([name isEqual:@"ac_cookies_import"]) {
    FixtureWrite(@"Cookies", args);
    result = @{ @"imported": @([args[@"cookies"] count]), @"rejected": @0, @"existing": @0 };
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
  NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  reply(context, output.UTF8String);
}

#define FIXTURE_CALL(symbol) void symbol(const char *profile, const char *args, void (*reply)(void *, const char *), void *context) { FixtureCall(@#symbol, profile, args, reply, context); }
FIXTURE_CALL(ac_passwords_add)
FIXTURE_CALL(ac_passwords_update)
FIXTURE_CALL(ac_passwords_remove)
FIXTURE_CALL(ac_passwords_reveal)
FIXTURE_CALL(ac_autofill_save_address)
FIXTURE_CALL(ac_autofill_save_card)
FIXTURE_CALL(ac_autofill_remove)
FIXTURE_CALL(ac_autofill_addresses)
FIXTURE_CALL(ac_autofill_cards)
FIXTURE_CALL(ac_autofill_import)
FIXTURE_CALL(ac_cookies_import)
FIXTURE_CALL(ac_bookmarks_apply)
FIXTURE_CALL(ac_history_delete_urls)
FIXTURE_CALL(ac_history_import)

void *FixtureSymbol(void *, const char *name) {
#define FIXTURE_SYMBOL(symbol) if (!strcmp(name, #symbol)) return (void *)&symbol;
  FIXTURE_SYMBOL(ac_passwords_add)
  FIXTURE_SYMBOL(ac_passwords_update)
  FIXTURE_SYMBOL(ac_passwords_remove)
  FIXTURE_SYMBOL(ac_passwords_reveal)
  FIXTURE_SYMBOL(ac_autofill_save_address)
  FIXTURE_SYMBOL(ac_autofill_save_card)
  FIXTURE_SYMBOL(ac_autofill_remove)
  FIXTURE_SYMBOL(ac_autofill_addresses)
  FIXTURE_SYMBOL(ac_autofill_cards)
  FIXTURE_SYMBOL(ac_autofill_import)
  FIXTURE_SYMBOL(ac_cookies_import)
  FIXTURE_SYMBOL(ac_bookmarks_apply)
  FIXTURE_SYMBOL(ac_history_delete_urls)
  FIXTURE_SYMBOL(ac_history_import)
  return nullptr;
}
#define dlsym FixtureSymbol

__PRODUCTION__

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    fixture = @(argv[1]);
    SolaraCoreHost.safeMode = [@(argv[2]) isEqual:@"safe"];
    NSString *category = @(argv[3]);
    received = [NSMutableArray array];
    NSMutableArray *results = [NSMutableArray array];
    SolaraCoreResult done = ^(NSDictionary *value) { [results addObject:value ?: @{}]; };
    if ([category isEqual:@"passwords"]) {
      if (SolaraCoreHost.safeMode) {
        [SolaraCoreServices savePassword:@"1" origin:@"https://login.example/path?query" username:@"before" password:@"secret" completion:done];
        [SolaraCoreServices updatePassword:@"1" origin:@"https://login.example/another" username:@"before" newUsername:@"after" newPassword:@"edited" completion:done];
        [SolaraCoreServices savePassword:@"1" origin:@"https://obsolete.example/path" username:@"deleted" password:@"gone" completion:done];
        [SolaraCoreServices deletePassword:@"1" origin:@"https://obsolete.example/path" username:@"deleted" completion:done];
      } else {
        [SolaraCoreServices password:@"1" origin:@"https://login.example/normal" username:@"after" completion:done];
        [SolaraCoreServices password:@"1" origin:@"https://login.example/normal" username:@"before" completion:done];
        [SolaraCoreServices password:@"1" origin:@"https://obsolete.example/normal" username:@"deleted" completion:done];
      }
    } else if ([category isEqual:@"bookmarks"] || [category isEqual:@"history"]) {
      if (SolaraCoreHost.safeMode) {
        NSArray *calls = [category isEqual:@"bookmarks"] ? @[
          @[ @"ac_bookmarks_apply", @{ @"ops": @[
            @{ @"op": @"add", @"id": @"fixture-bookmark", @"k": @"u", @"t": @"Before", @"u": @"https://before.example/", @"parent": @"bar", @"a": @42 },
            @{ @"op": @"update", @"id": @"fixture-bookmark", @"t": @"Safe edit", @"u": @"https://edited.example/" },
            @{ @"op": @"add", @"id": @"removed-bookmark", @"k": @"u", @"t": @"Removed", @"u": @"https://removed.example/", @"parent": @"bar", @"a": @43 },
            @{ @"op": @"remove", @"id": @"removed-bookmark" }
          ] } ]
        ] : @[
          @[ @"ac_history_import", @{ @"rows": @[ @{ @"u": @"https://deleted.example/", @"t": @"Deleted", @"n": @1, @"l": @42 }, @{ @"u": @"https://kept.example/", @"t": @"Kept", @"n": @1, @"l": @43 } ] } ],
          @[ @"ac_history_delete_urls", @{ @"urls": @[ @"https://deleted.example/" ] } ]
        ];
        for (NSArray *call in calls) {
          NSString *body = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:call[1] options:0 error:nil] encoding:NSUTF8StringEncoding];
          [SolaraCoreEngineBridge call:call[0] profile:@"1" args:body completion:^(NSString *json) {
            [results addObject:[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]];
          }];
        }
      }
    } else if ([category isEqual:@"autofill"]) {
      if (SolaraCoreHost.safeMode) {
        [SolaraCoreServices saveAddress:@{ @"id": @"home", @"name": @"Safe edit", @"street": @42, @"ignored": @[] } profile:@"1" completion:done];
        [SolaraCoreServices saveAddress:@{ @"id": @"obsolete", @"name": @"Delete me" } profile:@"1" completion:done];
        [SolaraCoreServices deleteAutofillEntry:@"obsolete" profile:@"1" completion:done];
        [SolaraCoreServices saveCard:@{ @"id": @"card", @"name": @"Safe card", @"expMonth": @12, @"expYear": @2030 } number:@"4111111111111111" profile:@"1" completion:done];
      } else {
        [SolaraCoreServices addresses:@"1" completion:done];
        [SolaraCoreServices cards:@"1" completion:done];
      }
    } else if ([category isEqual:@"import"]) {
      if (SolaraCoreHost.safeMode) {
        for (NSArray *call in @[
          @[ @"ac_cookies_import", @{ @"cookies": @[ @{ @"name": @"fixture", @"value": @"safe import", @"domain": @".example.test", @"path": @"/" } ] } ],
          @[ @"ac_autofill_import", @{ @"addresses": @[ @{ @"name": @"Imported address", @"street": @"42 Fixture Street" } ], @"cards": @[ @{ @"number": @"4111111111111111", @"name": @"Imported card" } ] } ]
        ]) {
          NSMutableData *args = [[NSJSONSerialization dataWithJSONObject:call[1] options:0 error:nil] mutableCopy];
          [args appendBytes:"" length:1];
          [SolaraCoreEngineBridge callWithSecret:call[0] profile:@"1" args:args completion:^(NSString *json) {
            [results addObject:[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]];
          }];
          BOOL wiped = YES;
          for (NSUInteger i = 0; i < args.length; i++) if (((const unsigned char *)args.bytes)[i]) wiped = NO;
          [results addObject:@{ @"wiped": @(wiped) }];
        }
      } else {
        [SolaraCoreServices addresses:@"1" completion:done];
        [SolaraCoreServices cards:@"1" completion:done];
      }
    }
    NSDictionary *output = @{ @"safe": @(SolaraCoreHost.safeMode), @"received": received, @"results": results,
      @"files": [NSFileManager.defaultManager contentsOfDirectoryAtPath:fixture error:nil] ?: @[],
      @"login": FixtureRead(@"Login Data"), @"web": FixtureRead(@"Web Data"), @"cookies": FixtureRead(@"Cookies"),
      @"bookmarks": FixtureRead(@"Bookmarks"), @"history": FixtureRead(@"History") };
    NSData *json = [NSJSONSerialization dataWithJSONObject:output options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
  }
}
