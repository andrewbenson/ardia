#import <Foundation/Foundation.h>

@interface SolaraCoreHost : NSObject
@property(class) BOOL safeMode;
@property(class, readonly) NSString *dataDirectory;
@end
@implementation SolaraCoreHost
static BOOL safe = NO;
+ (BOOL)safeMode { return safe; }
+ (void)setSafeMode:(BOOL)value { safe = value; }
+ (NSString *)dataDirectory { return @(getenv("TMPDIR")); }
@end
namespace solaracore_host { BOOL IsIncognito(NSString *) { return NO; } }
__PRODUCTION__
int main() {
  @autoreleasepool {
    NSMutableArray *results = [NSMutableArray array];
    NSString *dir = [SolaraCoreHost.dataDirectory stringByAppendingPathComponent:@"Profile 1"];
    NSString *path = [dir stringByAppendingPathComponent:@"Solara Favicons/icon.png"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSNumber *mode in @[ @YES, @NO ]) {
      SolaraCoreHost.safeMode = mode.boolValue;
      NSDictionary *result = Store([@"png fixture" dataUsingEncoding:NSUTF8StringEncoding], 32, 32, @"1", @"icon");
      NSArray *files = [NSFileManager.defaultManager subpathsAtPath:dir];
      NSData *data = [NSData dataWithContentsOfFile:path];
      [results addObject:@{ @"safe": mode, @"result": result ?: @{}, @"files": files ?: @[],
                           @"stored": data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"" }];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
  }
}
