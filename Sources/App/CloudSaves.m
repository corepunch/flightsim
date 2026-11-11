#import "App.h"
#import "Story.h"
#import <GameKit/GameKit.h>

static NSString *const SavePrefix = @"KestrelFrontier.Progress.";

// Use a separate filename for each installation so concurrent saves on two
// online devices cannot overwrite each other before either can fetch.
static NSString *InstallationSaveName(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *support = [files URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                         appropriateForURL:nil create:YES error:nil];
    if (!support) return nil;
    NSURL *folder = [support URLByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier isDirectory:YES];
    if (![files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    NSURL *url = [folder URLByAppendingPathComponent:@"CloudSaveInstallation"];
    NSString *identifier = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (![[NSUUID alloc] initWithUUIDString:identifier ?: @""]) {
        identifier = NSUUID.UUID.UUIDString;
        if (![identifier writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]) return nil;
        [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
    return [SavePrefix stringByAppendingString:identifier];
}

typedef struct { id iCloud; NSString *player; } SaveAccount;

static SaveAccount CurrentSaveAccount(void) {
    GKLocalPlayer *player = GKLocalPlayer.localPlayer;
    if (!player.authenticated) return (SaveAccount){0};
    return (SaveAccount){ NSFileManager.defaultManager.ubiquityIdentityToken, player.gamePlayerID };
}

static BOOL AccountStillCurrent(SaveAccount account) {
    SaveAccount now = CurrentSaveAccount();
    return [now.iCloud isEqual:account.iCloud] && [now.player isEqualToString:account.player];
}

@interface CloudSaves () <GKLocalPlayerListener>
@end

@implementation CloudSaves {
    NSString *_saveName;
    BOOL _registered, _syncing, _pending, _retryScheduled;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
#if TARGET_OS_IOS
        NSNotificationName active = UIApplicationDidBecomeActiveNotification;
#else
        NSNotificationName active = NSApplicationDidBecomeActiveNotification;
#endif
        [center addObserver:self selector:@selector(syncNotification:) name:active object:nil];
        [center addObserver:self selector:@selector(syncNotification:) name:NSUbiquityIdentityDidChangeNotification object:nil];
    }
    return self;
}

- (void)syncNotification:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ [self requestSync]; });
}

- (void)requestSync {
    SaveAccount account = CurrentSaveAccount();
    if (!account.player.length) return;
    if (!_registered) {
        [GKLocalPlayer.localPlayer registerListener:self];
        _registered = YES;
    }
    if (!account.iCloud) return;
    if (_syncing) { _pending = YES; return; }
    if (!_saveName) _saveName = InstallationSaveName();
    if (!_saveName) {
        [self retryLater];
        return;
    }
    _syncing = YES;
    [GKLocalPlayer.localPlayer fetchSavedGamesWithCompletionHandler:^(NSArray<GKSavedGame *> *games, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!AccountStillCurrent(account) || error) {
                [self finishSync:account error:error];
            } else {
                [self loadGames:games account:account];
            }
        });
    }];
}

- (void)loadGames:(NSArray<GKSavedGame *> *)games account:(SaveAccount)account {
    dispatch_group_t reads = dispatch_group_create();
    NSMutableArray<GKSavedGame *> *ownGames = [NSMutableArray array];
    __block ProgressSave *cloud = [ProgressSave empty];
    __block NSError *readError;
    __block BOOL ownSaveUnreadable = NO;
    for (GKSavedGame *game in games) {
        if (![game.name hasPrefix:SavePrefix]) continue;
        BOOL own = [game.name isEqualToString:_saveName];
        if (own) [ownGames addObject:game];
        dispatch_group_enter(reads);
        [game loadDataWithCompletionHandler:^(NSData *data, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ProgressSave *save = error ? nil : [ProgressSave fromData:data];
                if (save) cloud = [cloud merging:save];
                else if (error) readError = error;
                else if (own) ownSaveUnreadable = YES;
                dispatch_group_leave(reads);
            });
        }];
    }
    dispatch_group_notify(reads, dispatch_get_main_queue(), ^{
        if (!AccountStillCurrent(account)) { [self finishSync:account error:nil]; return; }
        ProgressSave *merged = ProgressMerge(cloud);
        if (readError || ownSaveUnreadable || (ownGames.count <= 1 && [merged isEqual:cloud])) {
            [self finishSync:account error:readError];
            return;
        }
        [self writeSave:merged replacingConflicts:ownGames account:account];
    });
}

- (void)writeSave:(ProgressSave *)save replacingConflicts:(NSArray<GKSavedGame *> *)games account:(SaveAccount)account {
    NSData *data = save.encodedData;
    void (^complete)(NSError *) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishSync:account error:error]; });
    };
    GKLocalPlayer *player = GKLocalPlayer.localPlayer;
    if (games.count > 1) {
        [player resolveConflictingSavedGames:games withData:data completionHandler:^(NSArray<GKSavedGame *> *resolved, NSError *error) {
            complete(error);
        }];
    } else {
        [player saveGameData:data withName:_saveName completionHandler:^(GKSavedGame *saved, NSError *error) {
            complete(error);
        }];
    }
}

- (void)finishSync:(SaveAccount)account error:(NSError *)error {
    _syncing = NO;
    BOOL pending = _pending;
    _pending = NO;
    if (!AccountStillCurrent(account)) {
        [self requestSync];
    } else if (error) {
        NSLog(@"GameKit progress sync: %@", error.localizedDescription);
        [self retryLater];
    } else if (pending) {
        [self requestSync];
    }
}

- (void)retryLater {
    if (_retryScheduled) return;
    _retryScheduled = YES;
    __weak CloudSaves *owner = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        CloudSaves *saves = owner;
        if (!saves) return;
        saves->_retryScheduled = NO;
        [saves requestSync];
    });
}

- (void)player:(GKPlayer *)player didModifySavedGame:(GKSavedGame *)savedGame {
    if ([savedGame.name hasPrefix:SavePrefix]) [self syncNotification:nil];
}

- (void)player:(GKPlayer *)player hasConflictingSavedGames:(NSArray<GKSavedGame *> *)savedGames {
    dispatch_async(dispatch_get_main_queue(), ^{
        // The fetch already includes every version. Ignore its own conflict
        // callback to avoid fetching the same set again indefinitely.
        if (!self->_syncing) [self requestSync];
    });
}
@end
