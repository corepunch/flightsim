#import "Progress.h"
#import "Assets.h"

static NSString *const kUnlockedKey = @"SFMissionsUnlocked";
static NSString *const kStartedKey = @"SFCampaignStarted";
static NSString *const kCompletedKey = @"SFCampaignCompleted";

NSUInteger ProgressUnlockedCount(void) {
    NSUInteger total = CampaignMissions().count;
    if (getenv("SF_UNLOCK_ALL")) return total;
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
