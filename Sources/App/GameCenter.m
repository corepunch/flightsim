#import "App.h"
#import "Common.h"
#import "Shared.h"
#import "Story.h"
#import <GameKit/GameKit.h>

static NSString *const PilotLeaderboard = @"com.corepunch.spacefight.pilot_score";

#if TARGET_OS_IOS
typedef UIViewController GameCenterSignIn;
#else
typedef NSViewController GameCenterSignIn;
#endif

static BOOL AuthenticationErrorIsTransient(NSError *error) {
    if ([error.domain isEqualToString:GKErrorDomain])
        return error.code == GKErrorCommunicationsFailure || error.code == GKErrorConnectionTimeout;
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorTimedOut:
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorDNSLookupFailed:
            return YES;
        default:
            return NO;
    }
}

@interface GameCenter () <GKGameCenterControllerDelegate>
@end

@implementation GameCenter {
    __weak SCNView *_view;
    GameCenterSignIn *_signIn;
#if TARGET_OS_IOS
    __weak UIViewController *_presentedSignIn;
#endif
    GKGameCenterViewController *_dashboard;
    CloudSaves *_cloudSaves;
    NSString *_submittedPlayer;
    NSUInteger _submitted;
    NSString *_friendsPlayer;
    NSDate *_friendsRead;
    BOOL _started, _authResolved, _openRequested, _submitting, _authRetryScheduled, _readingFriends;
}

- (instancetype)initWithView:(SCNView *)view {
    if ((self = [super init])) _view = view;
    return self;
}

- (BOOL)available {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.corepunch.spacefight"] &&
           [FSGame() isEqualToString:@"KestrelFrontier"];
}

- (void)startAuthentication {
    if (_started) return;
    _started = YES;
    _cloudSaves = [CloudSaves new];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(progressChanged:)
                                                name:ProgressDidChange object:nil];
    [self authenticate];
}

- (void)authenticate {
    _authResolved = NO;
    __weak GameCenter *owner = self;
    GKLocalPlayer.localPlayer.authenticateHandler = ^(GameCenterSignIn *controller, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [owner authenticationChanged:controller error:error]; });
    };
}

- (void)retryAuthenticationAfterError:(NSError *)error {
    if (_authRetryScheduled || !AuthenticationErrorIsTransient(error)) return;
    _authRetryScheduled = YES;
    __weak GameCenter *owner = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        GameCenter *center = owner;
        if (!center) return;
        center->_authRetryScheduled = NO;
        if (center->_authResolved && !GKLocalPlayer.localPlayer.authenticated) [center authenticate];
    });
}

- (void)authenticationChanged:(GameCenterSignIn *)controller error:(NSError *)error {
    _signIn = controller;
    _authResolved = !controller;
    if (error) {
        NSLog(@"Game Center authentication: %@", error.localizedDescription);
        if (_authResolved && !GKLocalPlayer.localPlayer.authenticated) [self retryAuthenticationAfterError:error];
    }
    [self submitIfNeeded];
    [self readFriendsIfDue];
    [_cloudSaves requestSync];
    [self openIfRequested];
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self available]) return;
        [self startAuthentication];
        [self submitIfNeeded];
        [self readFriendsIfDue];
        [self->_cloudSaves requestSync];
    });
}

- (void)progressChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self available]) return;
        [self submitIfNeeded];
        [self->_cloudSaves requestSync];
    });
}

- (void)submitIfNeeded {
    GKLocalPlayer *player = GKLocalPlayer.localPlayer;
    if (_submitting || !player.authenticated || ![self available]) return;
    NSString *playerID = player.gamePlayerID;
    NSUInteger score = ProgressPilotScore();
    if (!score) return;
    if ([_submittedPlayer isEqualToString:playerID] && score <= _submitted) return;
    _submitting = YES;
    // The context carries the campaign mission the pilot has reached; friends read it back.
    [GKLeaderboard submitScore:(NSInteger)score context:ProgressCampaignTag() player:player leaderboardIDs:@[PilotLeaderboard]
              completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_submitting = NO;
            if (error) {
                NSLog(@"Game Center score submission: %@", error.localizedDescription);
            } else {
                self->_submittedPlayer = playerID;
                self->_submitted = score;
            }
            // A result or an account change may have arrived during the upload.
            if (ProgressPilotScore() > score || ![playerID isEqualToString:GKLocalPlayer.localPlayer.gamePlayerID])
                [self submitIfNeeded];
        });
    }];
}

// Friends' Pilot Score entries say which mission each has reached. The list is
// read again when the menus come back, at most once a minute, and at once for
// another account.
- (void)readFriendsIfDue {
    GKLocalPlayer *player = GKLocalPlayer.localPlayer;
    if (!player.authenticated) {
        _friendsPlayer = nil;
        self.missionFriends = nil;
        return;
    }
    NSString *playerID = player.gamePlayerID;
    BOOL sameAccount = [_friendsPlayer isEqualToString:playerID];
    if (_readingFriends || (sameAccount && _friendsRead.timeIntervalSinceNow > -60)) return;
    if (!sameAccount) self.missionFriends = nil;
    _readingFriends = YES;
    _friendsPlayer = playerID;
    _friendsRead = NSDate.date;
    void (^finish)(NSArray<GKLeaderboardEntry *> *, NSError *) = ^(NSArray<GKLeaderboardEntry *> *entries, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_readingFriends = NO;
            if (error) NSLog(@"Game Center friends: %@", error.localizedDescription);
            else if ([playerID isEqualToString:GKLocalPlayer.localPlayer.gamePlayerID]) [self showFriendEntries:entries];
        });
    };
    [GKLeaderboard loadLeaderboardsWithIDs:@[PilotLeaderboard] completionHandler:^(NSArray<GKLeaderboard *> *boards, NSError *error) {
        if (!boards.count) { finish(nil, error); return; }
        [boards.firstObject loadEntriesForPlayerScope:GKLeaderboardPlayerScopeFriendsOnly timeScope:GKLeaderboardTimeScopeAllTime
                                                range:NSMakeRange(1, 100)
                                    completionHandler:^(GKLeaderboardEntry *own, NSArray<GKLeaderboardEntry *> *entries,
                                                        NSInteger total, NSError *entriesError) {
            finish(entries, entriesError);
        }];
    }];
}

// Entries arrive best score first, so each mission lists its strongest pilots first.
- (void)showFriendEntries:(NSArray<GKLeaderboardEntry *> *)entries {
    NSMutableArray<NSMutableArray<NSString *> *> *missions = [NSMutableArray array];
    for (NSUInteger i = 0; i < CampaignMissions().count; i++) [missions addObject:[NSMutableArray array]];
    NSString *own = GKLocalPlayer.localPlayer.gamePlayerID;
    for (GKLeaderboardEntry *entry in entries) {
        NSUInteger mission = CampaignIndexOfTag(entry.context);
        NSString *name = entry.player.displayName;
        if (mission < missions.count && name.length && ![entry.player.gamePlayerID isEqualToString:own])
            [missions[mission] addObject:name];
    }
    self.missionFriends = missions;
}

- (void)showLeaderboard {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self available]) {
            [self showNotice:L10n(@"score.unavailable")];
            return;
        }
        self->_openRequested = YES;
        [self startAuthentication];
        [self submitIfNeeded];
        [self openIfRequested];
    });
}

- (void)openIfRequested {
    if (!_openRequested || _dashboard || !_view.window) return;
#if TARGET_OS_IOS
    UIViewController *presenter = _view.window.rootViewController;
    if (!presenter) return;
    UIViewController *presented = presenter.presentedViewController;
    if (presented) {
        if (presented == _presentedSignIn && _authResolved) {
            // GameKit can complete authentication before the sign-in sheet closes.
            [presenter dismissViewControllerAnimated:YES completion:^{ [self openIfRequested]; }];
        }
        return;
    }
#endif
    if (_signIn) {
        GameCenterSignIn *controller = _signIn;
        _signIn = nil;
#if TARGET_OS_IOS
        _presentedSignIn = controller;
        [presenter presentViewController:controller animated:YES completion:nil];
#else
        GKDialogController *dialog = GKDialogController.sharedDialogController;
        dialog.parentWindow = _view.window;
        if (![dialog presentViewController:(NSViewController<GKViewController> *)controller]) {
            _openRequested = NO;
            _signIn = controller;
            [self showNotice:L10n(@"score.unavailable")];
        }
#endif
        return;
    }
    if (!GKLocalPlayer.localPlayer.authenticated) {
        if (!_authResolved) return;
        _openRequested = NO;
        [self showNotice:L10n(@"score.sign_in")];
        return;
    }
    _openRequested = NO;
    _dashboard = [[GKGameCenterViewController alloc] initWithLeaderboardID:PilotLeaderboard
                 playerScope:GKLeaderboardPlayerScopeGlobal timeScope:GKLeaderboardTimeScopeAllTime];
    _dashboard.gameCenterDelegate = self;
#if TARGET_OS_IOS
    _dashboard.modalInPresentation = YES;
    [presenter presentViewController:_dashboard animated:YES completion:nil];
#else
    GKDialogController *dialog = GKDialogController.sharedDialogController;
    dialog.parentWindow = _view.window;
    if (![dialog presentViewController:_dashboard]) {
        _dashboard = nil;
        [self showNotice:L10n(@"score.unavailable")];
    }
#endif
}

- (void)gameCenterViewControllerDidFinish:(GKGameCenterViewController *)controller {
#if TARGET_OS_IOS
    [controller dismissViewControllerAnimated:YES completion:nil];
#else
    [GKDialogController.sharedDialogController dismiss:controller];
#endif
    _dashboard = nil;
    _openRequested = NO;
}

- (void)showNotice:(NSString *)message {
    if (!_view.window) return;
    NSString *title = L10n(@"menu.leaderboards");
#if TARGET_OS_IOS
    UIViewController *presenter = _view.window.rootViewController;
    if (presenter.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L10n(@"browser.back") style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
#else
    if (_view.window.attachedSheet) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:L10n(@"browser.back")];
    [alert beginSheetModalForWindow:_view.window completionHandler:nil];
#endif
}
@end
