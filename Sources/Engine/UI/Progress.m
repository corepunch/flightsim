#import "Progress.h"
#import "Assets.h"

static NSString *const kUnlockedKey = @"SFMissionsUnlocked";

NSUInteger ProgressUnlockedCount(void) {
    NSUInteger total = CampaignMissions().count;
    if (getenv("SF_UNLOCK_ALL")) return total;
    NSInteger n = [[NSUserDefaults standardUserDefaults] integerForKey:kUnlockedKey];
    return MAX(1, MIN((NSUInteger)n, total));
}

void ProgressMarkCompleted(NSUInteger index) {
    NSUInteger next = MIN(index + 2, CampaignMissions().count);
    if (next > ProgressUnlockedCount()) [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)next forKey:kUnlockedKey];
}
