#import "Progress.h"
#import "Assets.h"
#import "Cvar.h"

static NSString *const kUnlockedKey = @"SFMissionsUnlocked";
static NSString *const kStartedKey = @"SFCampaignStarted";
static NSString *const kCompletedKey = @"SFCampaignCompleted";

static Cvar *UnlockAll(void) {
    static Cvar *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [Cvar get:@"ui_unlockAll" defaultValue:@"0" flags:CVAR_CHEAT help:@"Every mission is open"]; });
    return c;
}

NSUInteger ProgressUnlockedCount(void) {
    NSUInteger total = CampaignMissions().count;
    if (UnlockAll().boolValue) return total;
    NSInteger n = [[NSUserDefaults standardUserDefaults] integerForKey:kUnlockedKey];
    return MAX(1, MIN((NSUInteger)n, total));
}

BOOL ProgressHasStarted(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults boolForKey:kStartedKey] || [defaults integerForKey:kUnlockedKey] > 1;
}

BOOL ProgressCampaignCompleted(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:kCompletedKey];
}

void ProgressMarkStarted(void) {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kStartedKey];
}

void ProgressMarkCompleted(NSUInteger index) {
    NSUInteger total = CampaignMissions().count;
    if (index < total && index + 1 == total)
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kCompletedKey];
    NSUInteger next = MIN(index + 2, total);
    if (next > ProgressUnlockedCount()) [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)next forKey:kUnlockedKey];
}

NSUInteger ProgressBestStars(NSUInteger index) {
    NSNumber *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"SFMissionStars"][[NSString stringWithFormat:@"%lu", (unsigned long)index]];
    if (saved) return MIN(3, saved.unsignedIntegerValue);
    // Preserve completion earned before per-mission ratings existed.
    NSInteger unlocked = [NSUserDefaults.standardUserDefaults integerForKey:kUnlockedKey];
    return (index + 1 < (NSUInteger)MAX(1, unlocked) || (ProgressCampaignCompleted() && index + 1 == CampaignMissions().count)) ? 1 : 0;
}

void ProgressRecordResult(NSUInteger index, NSArray<NSString *> *results) {
    NSUInteger done = 0;
    for (NSString *line in results) if ([line hasPrefix:@"+"]) done++;
    NSUInteger stars = results.count == 0 ? 1 : done == results.count ? 3 : done * 4 >= results.count * 3 ? 2 : 1;
    stars = MAX(stars, ProgressBestStars(index));
    NSMutableDictionary *ratings = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"SFMissionStars"] mutableCopy] ?: [NSMutableDictionary dictionary];
    ratings[[NSString stringWithFormat:@"%lu", (unsigned long)index]] = @(stars);
    [NSUserDefaults.standardUserDefaults setObject:ratings forKey:@"SFMissionStars"];
}
