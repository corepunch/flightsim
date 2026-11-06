#pragma once

#import <Foundation/Foundation.h>

// MARK: - GameAudio

// All playback and file preparation run on a private serial queue.
@interface GameAudio : NSObject
+ (instancetype)shared;
- (void)play:(NSString *)name;
- (void)play:(NSString *)name gain:(float)gain pan:(float)pan;
- (void)radio:(NSString *)text;
- (void)clearRadio;
// Read-only playback state for audio checks, synchronized with the audio queue.
@property (nonatomic, readonly) BOOL radioPlaying;
@property (nonatomic, readonly) BOOL radioPending;
@property (nonatomic, readonly) NSString *radioText;
- (void)frame:(float)dt flying:(BOOL)flying;
- (void)shipThrottle:(float)throttle boost:(BOOL)boost alive:(BOOL)alive;
- (void)cycleMix;
- (NSString *)mixTitle;
@end
