#import "App.h"
#import <StoreKit/StoreKit.h>

// StoreKit's replacement for these calls is Swift only; they raise the same sheet.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
BOOL StoreRatingRequest(void) {
#if TARGET_OS_IOS
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        [SKStoreReviewController requestReviewInScene:(UIWindowScene *)scene];
        return YES;
    }
    return NO;
#else
    if (!NSApp.isActive) return NO;
    [SKStoreReviewController requestReview];
    return YES;
#endif
}
#pragma clang diagnostic pop
