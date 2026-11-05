#import <Foundation/Foundation.h>

// Campaign progress on this machine (NSUserDefaults): how many missions are
// open. A client-side record; the server never sees it.
NSUInteger ProgressUnlockedCount(void);     // at least 1
BOOL ProgressHasStarted(void);
BOOL ProgressCampaignCompleted(void);
void ProgressMarkStarted(void);
void ProgressMarkCompleted(NSUInteger missionIndex);

NSUInteger ProgressBestStars(NSUInteger missionIndex); // 0 unplayed, 1..3 best objective rating
void ProgressRecordResult(NSUInteger missionIndex, NSArray<NSString *> *results);
