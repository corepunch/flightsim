#import <Foundation/Foundation.h>

// Campaign progress on this machine (NSUserDefaults): how many missions are
// open. A client-side record; the server never sees it.
NSUInteger ProgressUnlockedCount(void);     // at least 1
void ProgressMarkCompleted(NSUInteger missionIndex);
