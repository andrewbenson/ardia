#import "SolaraCoreInternal.h"
#import "SolaraCoreWebView.h"

NS_ASSUME_NONNULL_BEGIN

@interface SolaraCoreWebView ()
- (void)openedTab:(SolaraCoreTab *)tab adoptId:(NSString *)adoptId disposition:(NSString *)disposition;
- (void)tabRemovedFromWindow:(SolaraCoreWindow *)window;
- (void)tabActivatedByChrome:(BOOL)chromes;
- (void)requestFocusRestore;
- (void)requestFocusRestoreIn:(NSWindow *)window;
- (void)devToolsChanged:(nullable NSView *)devToolsView;
@property (nonatomic, readonly, nullable) NSView *dockedDevToolsView;
- (void)emit:(NSString *)name payload:(NSDictionary<NSString *, id> *)payload;
+ (void)keepTransfersOfWindow:(NSWindow *)window;
+ (NSArray<SolaraCoreTab *> *)tabsToKeep:(NSArray<SolaraCoreTab *> *)tabs closingWindow:(NSWindow *)window closedByChrome:(BOOL)closedByChrome;
+ (void)moveKeptTabs:(NSArray<SolaraCoreTab *> *)tabs closingWindow:(NSWindow *)window;
@end

NS_ASSUME_NONNULL_END
