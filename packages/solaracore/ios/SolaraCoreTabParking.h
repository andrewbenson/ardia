#import "SolaraCoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SolaraCoreParkedPageHolder <SolaraCoreTabDelegate>
@property(nonatomic, readonly) BOOL closedByChrome;
@property(nonatomic, readonly) BOOL closedWithWindow;
@end

@interface SolaraCoreTabParking : NSObject

+ (void)park:(SolaraCoreTab *)tab forKey:(NSString *)key;
+ (nullable SolaraCoreTab *)parkedTabForKey:(NSString *)key;
+ (void)unpark:(NSString *)key;
+ (void)tookTransfer:(NSString *)key;
+ (void)releaseTransfer:(NSString *)key;
+ (BOOL)launchWasClosed:(NSString *)key;
+ (BOOL)launchClosedWithWindow:(NSString *)key;
+ (void)rehomeFromWindow:(SolaraCoreWindowController *)closing;

+ (void)keepOffscreen:(SolaraCoreTab *)tab holder:(id<SolaraCoreParkedPageHolder>)holder;
+ (nullable id<SolaraCoreParkedPageHolder>)takeHolderOfTab:(SolaraCoreTab *)tab;

+ (void)holdAcrossReload:(NSDictionary<NSString *, SolaraCoreTab *> *)tabs
                 expired:(void (^)(NSString *key, SolaraCoreTab *tab))expired;

@property(class, nonatomic, readonly, nullable) SolaraCoreTab *launchTab;
+ (void)holdLaunchTab:(NSString *)key
                  url:(NSString *)url
              profile:(NSString *)profile
              opening:(SolaraCoreTab *_Nullable (^)(void))open;
+ (void)claimLaunchTab:(NSString *)key url:(NSString *)url profile:(NSString *)profile;

@property(class, nonatomic, readonly, nullable) SolaraCoreTab *firstLinkTab;
+ (void)holdLinkTabs:(NSArray<NSString *> *)urls profile:(NSString *)profile opening:(SolaraCoreTab *_Nullable (^)(NSString *url))open;
+ (nullable NSString *)linkMarkForTab:(SolaraCoreTab *)tab;
+ (void)dismissLinkTab:(SolaraCoreTab *)tab;
+ (BOOL)takeDismissedLinkMark:(NSString *)mark;
+ (NSDictionary<NSString *, id> *)routeLinkTabs:(NSArray<NSString *> *)urls;
@property(class, nonatomic, readonly) BOOL linkTabsRouted;
+ (void)noteLittleWindowOpening;
@property(class, nonatomic, readonly, nullable) NSString *soleLinkURL;
@property(class, nonatomic, readonly, nullable) NSString *linkProfile;
+ (nullable SolaraCoreTab *)parkLinkTab:(NSString *)mark forKey:(nullable NSString *)key;
+ (void)discardTab:(SolaraCoreTab *)tab forKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
