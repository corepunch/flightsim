#pragma once
#import <Foundation/Foundation.h>

// All playback and file preparation run on a private serial queue.
@interface GameAudio : NSObject
+ (instancetype)shared;
- (void)play:(NSString *)name;
- (void)play:(NSString *)name gain:(float)gain pan:(float)pan;
- (void)frame:(float)dt flying:(BOOL)flying;
- (void)shipThrottle:(float)throttle boost:(BOOL)boost alive:(BOOL)alive;
- (void)cycleMix;
- (NSString *)mixTitle;
@end
