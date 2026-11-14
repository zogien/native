/* Desktop notifications for the AppKit host (appkit_host.m) and the
 * Chromium host (cef_host.mm). Each app links exactly one host, so the
 * class is defined here once per binary.
 *
 * Why NSUserNotificationCenter, deprecated since macOS 11, and not the
 * UserNotifications framework: usernoted refuses to mix the two in one
 * process, and Chromium (through CEF 144) opens a legacy connection in the
 * browser process at startup, so a Chromium app cannot use
 * UserNotifications at all. UserNotifications also rejects a bundle whose
 * code signature does not name the bundle id, which is what an unsigned
 * package carries. Move both hosts together once Chromium defaults to
 * UserNotifications (its `NewMacNotificationAPI` feature) or the legacy
 * center stops working.
 *
 * A notification carries only its record token (see
 * `notification_records.zig`); the commands stay in the Zig platform
 * layer. The host reports a click as the token plus its kind.
 *
 * Chromium also installs itself as the legacy center's delegate. This
 * object keeps the delegate it displaced and forwards every notification
 * that is not ours to it. */

#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* The click kinds, matching `notification_records.Activation`. */
enum {
    NativeSdkNotificationActivationBody = 0,
    NativeSdkNotificationActivationAction = 1,
};

typedef void (^NativeSdkNotificationActivationHandler)(NSString *token, int activation);

@interface NativeSdkUserNotifications : NSObject <NSUserNotificationCenterDelegate>
/* Called on the main thread with a nonempty token. */
@property(nonatomic, copy) NativeSdkNotificationActivationHandler activationHandler;
/* Whether this process can show notifications at all: the notification
 * center identifies the app by its bundle, so it must run from an app
 * bundle with a bundle identifier. Outside one the center is nil. */
+ (BOOL)available;
/* Deliver a notification; one with the same nonempty identifier replaces
 * it in place. Returns NO when notifications are unavailable. The first
 * notification makes macOS ask the user for permission, and nothing is
 * presented while notifications are off for the app. */
- (BOOL)showTitle:(NSString *)title subtitle:(NSString *)subtitle body:(NSString *)body identifier:(NSString *)identifier actionLabel:(NSString *)actionLabel token:(NSString *)token;
/* Hand the center's delegate back to the one this object displaced. */
- (void)detach;
@end

/* Marks a notification as ours; the value is the record token, empty for
 * a notification without commands. */
static NSString *const NativeSdkNotificationTokenKey = @"native-sdk-notification-token";

/* The token of one of our notifications, or nil for another client's. */
static NSString *NativeSdkNotificationToken(NSUserNotification *notification) {
    id token = notification.userInfo[NativeSdkNotificationTokenKey];
    return [token isKindOfClass:[NSString class]] ? token : nil;
}

@implementation NativeSdkUserNotifications {
    NSUserNotificationCenter *_center;
    __weak id<NSUserNotificationCenterDelegate> _displacedDelegate;
}

+ (BOOL)available {
    NSBundle *bundle = [NSBundle mainBundle];
    return bundle.bundleIdentifier.length > 0 &&
        [bundle.bundlePath.pathExtension caseInsensitiveCompare:@"app"] == NSOrderedSame;
}

/* Connects on first use, so an app that never notifies never talks to
 * the notification center (and never triggers its permission prompt). */
- (NSUserNotificationCenter *)center {
    if (_center) return _center;
    if (![NativeSdkUserNotifications available]) return nil;
    NSUserNotificationCenter *center = [NSUserNotificationCenter defaultUserNotificationCenter];
    if (!center) return nil;
    id<NSUserNotificationCenterDelegate> displaced = center.delegate;
    if (displaced != self) _displacedDelegate = displaced;
    center.delegate = self;
    _center = center;
    return center;
}

- (BOOL)showTitle:(NSString *)title subtitle:(NSString *)subtitle body:(NSString *)body identifier:(NSString *)identifier actionLabel:(NSString *)actionLabel token:(NSString *)token {
    if (title.length == 0 || (actionLabel.length > 0 && token.length == 0)) return NO;
    NSUserNotificationCenter *center = [self center];
    if (!center) return NO;
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = title;
    if (subtitle.length > 0) notification.subtitle = subtitle;
    if (body.length > 0) notification.informativeText = body;
    if (identifier.length > 0) notification.identifier = identifier;
    notification.userInfo = @{ NativeSdkNotificationTokenKey: token ?: @"" };
    notification.hasActionButton = actionLabel.length > 0;
    if (actionLabel.length > 0) notification.actionButtonTitle = actionLabel;
    [center deliverNotification:notification];
    return YES;
}

- (void)detach {
    self.activationHandler = nil;
    if (_center && _center.delegate == self) _center.delegate = _displacedDelegate;
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification {
    if (!NativeSdkNotificationToken(notification)) {
        id<NSUserNotificationCenterDelegate> displaced = _displacedDelegate;
        return [displaced respondsToSelector:_cmd] ? [displaced userNotificationCenter:center shouldPresentNotification:notification] : NO;
    }
    /* Show it while the app is frontmost too. */
    return YES;
}

- (void)userNotificationCenter:(NSUserNotificationCenter *)center didDeliverNotification:(NSUserNotification *)notification {
    if (NativeSdkNotificationToken(notification)) return;
    id<NSUserNotificationCenterDelegate> displaced = _displacedDelegate;
    if ([displaced respondsToSelector:_cmd]) [displaced userNotificationCenter:center didDeliverNotification:notification];
}

- (void)userNotificationCenter:(NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification {
    NSString *token = NativeSdkNotificationToken(notification);
    if (!token) {
        id<NSUserNotificationCenterDelegate> displaced = _displacedDelegate;
        if ([displaced respondsToSelector:_cmd]) [displaced userNotificationCenter:center didActivateNotification:notification];
        return;
    }
    int activation = -1;
    if (notification.activationType == NSUserNotificationActivationTypeContentsClicked) {
        activation = NativeSdkNotificationActivationBody;
    } else if (notification.activationType == NSUserNotificationActivationTypeActionButtonClicked) {
        activation = NativeSdkNotificationActivationAction;
    }
    /* A click consumes the notification. One without commands only
     * activates the app, which macOS does itself. The host's events are
     * main-thread only. */
    [center removeDeliveredNotification:notification];
    NativeSdkNotificationActivationHandler handler = self.activationHandler;
    NSString *tokenCopy = [token copy];
    if (!handler || activation < 0 || tokenCopy.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(tokenCopy, activation);
    });
}

@end

#pragma clang diagnostic pop
