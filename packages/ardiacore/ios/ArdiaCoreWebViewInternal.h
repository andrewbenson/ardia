#import "ArdiaCoreInternal.h"
#import "ArdiaCoreWebView.h"

NS_ASSUME_NONNULL_BEGIN

@interface ArdiaCoreWebView ()
- (void)openedTab:(ArdiaCoreTab *)tab adoptId:(NSString *)adoptId disposition:(NSString *)disposition;
- (void)tabRemovedFromWindow:(ArdiaCoreWindow *)window;
- (void)tabActivatedByChrome:(BOOL)chromes;
- (void)requestFocusRestore;
- (void)requestFocusRestoreIn:(NSWindow *)window;
- (void)devToolsChanged:(nullable NSView *)devToolsView;
- (void)emit:(NSString *)name payload:(NSDictionary<NSString *, id> *)payload;
- (void)exitPictureInPictureInFrame:(nullable NSString *)frameId;
+ (void)keepTransfersOfWindow:(NSWindow *)window;
@end

NS_ASSUME_NONNULL_END
