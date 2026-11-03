// The user notification centre's notifications, for an app in its bundle:
// macOS gives them to no other program, so outside one (as the host's
// tests are) they're only logged.

#include "platform.h"

#include <QCoreApplication>
#include <QMetaObject>

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

// Shown while the app is in front too, as on the other desktops, and the
// app opened at the key of the one clicked.
@interface HatterNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation HatterNotificationDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList
                      | UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler
{
    const QString key = QString::fromNSString(response.notification.request.identifier);
    QMetaObject::invokeMethod(qApp, [key] { notificationOpened(key); });
    completionHandler();
}

@end

// Before the app has started, so a click that starts it reaches it too.
Notifications::Notifications()
{
    if (NSBundle.mainBundle.bundleIdentifier) {
        HatterNotificationDelegate *delegate = [[HatterNotificationDelegate alloc] init];
        UNUserNotificationCenter.currentNotificationCenter.delegate = delegate;
        // The centre doesn't keep it.
        centre = (__bridge_retained void *)delegate;
    }
}

Notifications::~Notifications()
{
    if (centre) {
        UNUserNotificationCenter.currentNotificationCenter.delegate = nil;
        CFRelease(centre);
    }
}

// In place of the one with the same key, once the user lets the app
// notify, as macOS asks them the first time. A call as any other: banners
// go after a while, alerts (if the user chose those) stay until closed.
void Notifications::show(const QString &key, const QString &title, const QString &text, int)
{
    if (!centre) {
        qInfo("notification %s: %s", qUtf8Printable(key), qUtf8Printable(title));
        return;
    }
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title.toNSString();
    content.body = text.toNSString();
    content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:key.toNSString()
                                                                          content:content
                                                                          trigger:nil];
    UNUserNotificationCenter *notifications = UNUserNotificationCenter.currentNotificationCenter;
    // Answered later, when key is gone: the request has it.
    [notifications requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                                 completionHandler:^(BOOL granted, NSError *error) {
                                     if (granted) {
                                         [notifications addNotificationRequest:request
                                                         withCompletionHandler:^(NSError *added) {
                                                             if (added) {
                                                                 qWarning("notification %s not shown: %s",
                                                                          request.identifier.UTF8String,
                                                                          added.localizedDescription.UTF8String);
                                                             }
                                                         }];
                                     } else {
                                         qInfo("notification %s: not allowed (%s)", request.identifier.UTF8String,
                                               error ? error.localizedDescription.UTF8String : "by the user");
                                     }
                                 }];
}

void Notifications::cancel(const QString &key)
{
    if (centre) {
        NSArray<NSString *> *keys = @[ key.toNSString() ];
        [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:keys];
        [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:keys];
    }
}
