#import "GameAudio.h"
#import "FileSystem.h"
#import "Localization.h"
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const MixKey = @"SpaceFight.audioMix";
static const float MusicLevel = 0.28f, EffectsLevel = 0.8f;

@implementation GameAudio {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, NSArray<AVAudioPlayer *> *> *_effects;
    NSMutableDictionary<NSString *, NSNumber *> *_lastPlayed;
    NSArray<NSArray<AVAudioPlayer *> *> *_music;
    AVAudioPlayer *_engine, *_boost;
    NSMutableArray *_observers;
    NSUInteger _mix, _musicVoice[2];
    float _musicGain[2], _throttle;
    BOOL _alive, _boosting, _active, _interrupted, _flying;
}

+ (instancetype)shared {
    static GameAudio *audio;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ audio = [GameAudio new]; });
    return audio;
}

- (AVAudioPlayer *)load:(NSString *)name loop:(BOOL)loop {
    NSURL *url = FSURL(@"Audio", name, @"mp3");
    if (!url) { NSLog(@"Audio: missing %@.mp3", name); return nil; }
    NSError *error;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (!player) { NSLog(@"Audio: %@: %@", name, error); return nil; }
    player.numberOfLoops = loop ? -1 : 0;
    player.enableRate = [name isEqualToString:@"engine"];
    player.volume = 0;
    [player prepareToPlay];
    return player;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("SpaceFight.audio", DISPATCH_QUEUE_SERIAL);
        _effects = [NSMutableDictionary dictionary];
        _lastPlayed = [NSMutableDictionary dictionary];
        _observers = [NSMutableArray array];
        _active = YES;
        _mix = MIN(2, MAX(0, [NSUserDefaults.standardUserDefaults integerForKey:MixKey]));
        // Do not block the renderer on compressed-file preparation.
        dispatch_async(_queue, ^{
#if TARGET_OS_IOS
            NSError *error;
            [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryAmbient error:&error];
            if (error) NSLog(@"Audio session: %@", error);
            [AVAudioSession.sharedInstance setActive:YES error:nil];
#endif
            for (NSString *name in @[@"ui-hover", @"ui-confirm", @"ui-back", @"ui-panel", @"ui-alert",
                                      @"ui-success", @"laser", @"laser-player", @"secondary", @"impact", @"explosion"]) {
                NSMutableArray *voices = [NSMutableArray array];
                NSUInteger count = [@[@"laser", @"laser-player", @"impact", @"explosion"] containsObject:name] ? 4 : 2;
                for (NSUInteger i = 0; i < count; i++) {
                    AVAudioPlayer *p = [self load:[name isEqualToString:@"laser-player"] ? @"laser" : name loop:NO];
                    if (p) [voices addObject:p];
                }
                self->_effects[name] = voices;
            }
            NSMutableArray *tracks = [NSMutableArray array];
            for (NSString *name in @[@"bastion-watch", @"lancer-flight"]) {
                NSMutableArray *voices = [NSMutableArray array];
                for (int i = 0; i < 2; i++) {
                    AVAudioPlayer *p = [self load:name loop:NO];
                    if (p) [voices addObject:p];
                }
                [tracks addObject:voices];
            }
            self->_music = tracks;
            self->_engine = [self load:@"engine" loop:YES];
            self->_boost = [self load:@"boost" loop:YES];
        });
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
#if TARGET_OS_IOS
        NSString *off = UIApplicationWillResignActiveNotification, *on = UIApplicationDidBecomeActiveNotification;
        [_observers addObject:[nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                BOOL interrupted = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan;
                dispatch_async(self->_queue, ^{
                    self->_interrupted = interrupted;
                    if (interrupted) [self pauseAll];
                    else [AVAudioSession.sharedInstance setActive:YES error:nil];
                });
            }]];
#else
        NSString *off = NSApplicationDidResignActiveNotification, *on = NSApplicationDidBecomeActiveNotification;
#endif
        [_observers addObject:[nc addObserverForName:off object:nil queue:nil usingBlock:^(NSNotification *n) {
            dispatch_async(self->_queue, ^{ self->_active = NO; [self pauseAll]; });
        }]];
        [_observers addObject:[nc addObserverForName:on object:nil queue:nil usingBlock:^(NSNotification *n) {
            dispatch_async(self->_queue, ^{ self->_active = YES; });
        }]];
    }
    return self;
}

- (void)pauseAll {
    for (NSArray *track in _music) for (AVAudioPlayer *p in track) [p pause];
    [_engine pause];
    [_boost pause];
    for (NSArray *voices in _effects.allValues) for (AVAudioPlayer *p in voices) { [p stop]; p.currentTime = 0; }
}

- (NSString *)mixTitle {
    NSInteger mix = [NSUserDefaults.standardUserDefaults integerForKey:MixKey];
    return L10n(@[@"audio.mix_all", @"audio.mix_effects", @"audio.mix_muted"][MIN(2, MAX(0, mix))]);
}

- (void)cycleMix {
    NSInteger next = ([NSUserDefaults.standardUserDefaults integerForKey:MixKey] + 1) % 3;
    [NSUserDefaults.standardUserDefaults setInteger:next forKey:MixKey];
    dispatch_async(_queue, ^{
        self->_mix = next;
        if (next == 2) [self pauseAll];
        if (next != 0) {
            for (NSArray *track in self->_music) for (AVAudioPlayer *p in track) [p pause];
            self->_musicGain[0] = self->_musicGain[1] = 0;
        }
    });
}

- (void)play:(NSString *)name { [self play:name gain:1 pan:0]; }

- (void)play:(NSString *)name gain:(float)gain pan:(float)pan {
    if (gain < 0.015f) return;
    dispatch_async(_queue, ^{
        if (self->_mix == 2 || !self->_active || self->_interrupted) return;
        CFTimeInterval now = CACurrentMediaTime();
        double interval = [name isEqualToString:@"ui-hover"] ? 0.065 :
                          [name isEqualToString:@"ui-alert"] ? 3.0 :
                          [name isEqualToString:@"impact"] ? 0.07 : 0.035;
        if (self->_lastPlayed[name] && now - self->_lastPlayed[name].doubleValue < interval) return;
        NSArray<AVAudioPlayer *> *voices = self->_effects[name];
        AVAudioPlayer *voice = nil;
        for (AVAudioPlayer *p in voices) if (!p.playing) { voice = p; break; }
        if (!voice) return; // Bounded polyphony: a battle cannot allocate unbounded voices.
        self->_lastPlayed[name] = @(now);
        voice.currentTime = 0;
        float level = [name isEqualToString:@"ui-hover"] ? 0.20f :
                      [name hasPrefix:@"ui-"] ? 0.48f : 0.72f;
        voice.volume = EffectsLevel * level * fminf(1, fmaxf(0, gain));
        voice.pan = fminf(1, fmaxf(-1, pan));
        [voice play];
    });
}

- (void)shipThrottle:(float)throttle boost:(BOOL)boost alive:(BOOL)alive {
    dispatch_async(_queue, ^{
        self->_throttle = fminf(1, fmaxf(0, throttle));
        self->_boosting = boost;
        self->_alive = alive;
    });
}

- (void)frame:(float)dt flying:(BOOL)flying {
    dispatch_async(_queue, ^{
        if (self->_flying != flying) {
            self->_flying = flying;
            self->_alive = NO; // Await fresh ship state after a mission transition.
        }
        if (!self->_active || self->_interrupted || self->_mix == 2) return;
        float ease = 1 - expf(-fminf(dt, 0.1f) * 2.5f);
        for (NSUInteger i = 0; i < self->_music.count; i++) {
            NSArray<AVAudioPlayer *> *voices = self->_music[i];
            if (voices.count < 2) continue;
            float target = self->_mix == 0 && (i == (flying ? 1 : 0)) ? MusicLevel : 0;
            self->_musicGain[i] += (target - self->_musicGain[i]) * ease;
            AVAudioPlayer *current = voices[self->_musicVoice[i]], *next = voices[1 - self->_musicVoice[i]];
            if (self->_musicGain[i] < 0.001f && target == 0) { [current pause]; [next pause]; continue; }
            if (!current.playing && next.playing) {
                current.currentTime = 0;
                self->_musicVoice[i] = 1 - self->_musicVoice[i];
                AVAudioPlayer *old = current; current = next; next = old;
            }
            if (!current.playing) [current play];
            // Two prepared voices overlap the end and beginning, avoiding a hard music loop seam.
            double remaining = current.duration - current.currentTime;
            float blend = fminf(1, fmaxf(0, (2.0 - remaining) / 2.0));
            current.volume = self->_musicGain[i] * (1 - blend);
            if (blend > 0) {
                if (!next.playing) { next.currentTime = 0; [next play]; }
                next.volume = self->_musicGain[i] * blend;
                if (remaining < 0.08) {
                    [current stop]; current.currentTime = 0;
                    self->_musicVoice[i] = 1 - self->_musicVoice[i];
                }
            }
        }
        BOOL engineOn = flying && self->_alive;
        float engineLevel = engineOn ? EffectsLevel * (0.10f + 0.18f * self->_throttle) : 0;
        float boostLevel = engineOn && self->_boosting ? EffectsLevel * 0.36f : 0;
        self->_engine.rate = 0.85f + self->_throttle * 0.3f;
        [self updateLoop:self->_engine target:engineLevel ease:ease];
        [self updateLoop:self->_boost target:boostLevel ease:ease];
    });
}

- (void)updateLoop:(AVAudioPlayer *)player target:(float)target ease:(float)ease {
    player.volume += (target - player.volume) * ease;
    if (player.volume < 0.001f && target == 0) [player pause];
    else if (!player.playing) [player play];
}
@end
