#import <AppKit/AppKit.h>

@class SolaraCoreTab;

NS_ASSUME_NONNULL_BEGIN

@interface SolaraCoreEarlyWindow : NSObject
@property(class, nonatomic, readonly) BOOL switchedOff;
+ (void)setDataDirectory:(nullable NSString *)directory;
+ (void)noteLayoutChangeIn:(nullable NSWindow *)window;
+ (void)recordNow;
+ (void)prefetchForSession:(NSDictionary *)session;
+ (void)discardPrefetch;
+ (BOOL)canShowWindow:(NSString *)windowId session:(NSDictionary *)session;
+ (BOOL)showWindow:(NSString *)windowId
             frame:(NSArray<NSNumber *> *)frame
               key:(NSString *)key
           profile:(NSString *)profile
          backdrop:(NSDictionary *)backdrop;
+ (void)attachPage:(SolaraCoreTab *)tab key:(NSString *)key;
+ (BOOL)showLittleWindowForLink:(SolaraCoreTab *)tab
                           mark:(NSString *)mark
                            url:(NSString *)url
                          frame:(NSArray<NSNumber *> *)frame
                        profile:(NSString *)profile
                       backdrop:(NSDictionary *)backdrop
                           like:(nullable NSString *)windowId;
+ (nullable NSWindow *)claimLittleWindowForLink:(NSString *)mark profile:(nullable NSString *)profile;
@property(class, nonatomic, readonly) NSUInteger unclaimedLittleWindows;
+ (void)forgetPictures;
+ (void)forgetPicturesNow;
+ (BOOL)holdsPage:(SolaraCoreTab *)tab;
+ (nullable NSWindow *)claimForAppWindow:(nullable NSString *)windowId profile:(nullable NSString *)profile;
+ (BOOL)takeDismissed:(nullable NSString *)windowId;
+ (nullable NSView *)coverInWindow:(nullable NSWindow *)window;
+ (void)rootEmbedded:(NSView *)root inWindow:(NSWindow *)window;
+ (void)pageMoved:(SolaraCoreTab *)tab;
+ (void)pageNavigated:(nullable SolaraCoreTab *)tab launchURL:(nullable NSString *)launchURL;
+ (BOOL)veils:(nullable SolaraCoreTab *)tab;
+ (void)requestFocus:(nullable SolaraCoreTab *)tab;
+ (void)page:(nullable SolaraCoreTab *)tab shownURL:(nullable NSString *)url;
+ (void)pageCommitted:(nullable SolaraCoreTab *)tab shownURL:(nullable NSString *)url;
+ (void)page:(nullable SolaraCoreTab *)tab emitted:(nullable NSString *)url;
+ (void)dropPage:(nullable SolaraCoreTab *)tab;
@end

NS_ASSUME_NONNULL_END
