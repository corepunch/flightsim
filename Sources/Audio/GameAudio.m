#import "Audio.h"
#import "Shared.h"
#import "Common.h"
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const MixKey = @"KestrelFrontier.audioMix";
static const float MusicLevel = 0.28f, EffectsLevel = 0.8f;

// A catalog entry keeps the subtitle key and its authored recording together.
@interface RadioLine : NSObject
@property (nonatomic, readonly) NSString *identifier, *text;
@property (nonatomic, readonly) NSURL *url;
- (instancetype)initWithJSON:(id)json;
@end

@implementation RadioLine
- (instancetype)initWithJSON:(id)json {
    NSString *file = JSONString(json, @"file");
    NSString *text = JSONString(json, @"text");
    if (!file.length || ![file.lastPathComponent isEqualToString:file] || !text.length) return nil;
    NSURL *url = FSURL(@"Audio/Radio", file.stringByDeletingPathExtension, file.pathExtension);
    if (!url) { NSLog(@"Radio: missing %@", file); return nil; }
    if ((self = [super init])) {
        _identifier = [JSONString(json, @"key") copy]; _text = [text copy]; _url = url;
    }
    return self;
}
@end

typedef struct { RadioLine *line; CFTimeInterval until; } PendingRadio;

// One shared frequency; stale chatter is discarded instead of building a backlog.
@interface RadioChannel : NSObject
@property (nonatomic, readonly) BOOL playing, pending;
@property (nonatomic, readonly) NSString *text;
- (void)transmit:(NSString *)text;
- (void)update;
- (void)clear;
@end

@implementation RadioChannel {
    NSString *_game;
    NSArray<RadioLine *> *_lines;
    RadioLine *_current;
    AVAudioPlayer *_voice;
    PendingRadio _waiting;
    CFTimeInterval _nextAt;
    Cvar *_volume;
}
- (instancetype)init {
    if ((self = [super init]))
        _volume = [Cvar get:@"s_radioVolume" defaultValue:@"0.32" flags:CVAR_ARCHIVE help:@"Background radio voice volume (0–1)"];
    return self;
}
- (BOOL)playing { return _voice.playing; }
- (BOOL)pending { return _waiting.line != nil; }
- (NSString *)text { return _current.text ?: @""; }
- (void)clear {
    [_voice stop]; _voice = nil;
    _current = nil; _waiting = (PendingRadio){0}; _nextAt = 0;
}
- (void)loadCatalog {
    NSString *game = FSGame();
    if ([_game isEqualToString:game]) return;
    [self clear]; _game = [game copy];
    id json = FSJSON(FSURL(@"Audio/Radio", @"catalog", @"json"));
    NSMutableArray *lines = [NSMutableArray array];
    for (id entry in JSONArray(json, @"lines")) {
        RadioLine *line = [[RadioLine alloc] initWithJSON:entry];
        if (line) [lines addObject:line];
    }
    _lines = [lines copy];
}
- (void)start:(RadioLine *)line {
    // Keep a decoder only for the recording on air, rather than preparing the
    // entire campaign catalog when the first radio message arrives.
    NSError *error = nil;
    _voice = [[AVAudioPlayer alloc] initWithContentsOfURL:line.url error:&error];
    if (!_voice) { NSLog(@"Radio: cannot play %@: %@", line.url.lastPathComponent, error); return; }
    _current = line;
    _voice.volume = fminf(1, fmaxf(0, _volume.value));
    [_voice play];
}
- (void)transmit:(NSString *)text {
    [self loadCatalog];
    [self update];
    if (_volume.value <= 0) return;
    NSString *key = [text hasPrefix:@"{#"] && [text hasSuffix:@"}"] ? [text substringWithRange:NSMakeRange(2, text.length - 3)] : text;
    for (RadioLine *line in _lines) {
        if (![line.identifier isEqualToString:key] && ![line.text isEqualToString:text]) continue;
        if (_current == line || _waiting.line == line) return;
        CFTimeInterval now = CACurrentMediaTime();
        if (!_current && now >= _nextAt) [self start:line];
        else if (!_waiting.line) _waiting = (PendingRadio){line, now + 6};
        return;
    }
}
- (void)update {
    CFTimeInterval now = CACurrentMediaTime();
    if (_volume.value <= 0) { [self clear]; return; }
    if (_current && !_voice.playing) { _current = nil; _voice = nil; _nextAt = now + 1.25; }
    if (_waiting.line && now > _waiting.until) _waiting = (PendingRadio){0};
    if (!_current && _waiting.line && now >= _nextAt) {
        RadioLine *line = _waiting.line;
        _waiting = (PendingRadio){0}; [self start:line];
    }
}
@end

@implementation GameAudio {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, NSArray<AVAudioPlayer *> *> *_effects;
    NSMutableDictionary<NSString *, NSNumber *> *_lastPlayed;
    NSArray<NSArray<AVAudioPlayer *> *> *_music;
    AVAudioPlayer *_engine, *_boost;
    RadioChannel *_radio;
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
    NSURL *url = FSURL(@"Audio", name, @"wav") ?: FSURL(@"Audio", name, @"mp3");
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
        _queue = dispatch_queue_create("KestrelFrontier.audio", DISPATCH_QUEUE_SERIAL);
        _effects = [NSMutableDictionary dictionary];
        _lastPlayed = [NSMutableDictionary dictionary];
        _observers = [NSMutableArray array];
        _active = YES;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        // The key was SpaceFight.audioMix before the game took its real name.
        id legacy = [defaults objectForKey:@"SpaceFight.audioMix"];
        if (legacy && ![defaults objectForKey:MixKey]) [defaults setObject:legacy forKey:MixKey];
        if (legacy) [defaults removeObjectForKey:@"SpaceFight.audioMix"];
        _mix = MIN(2, MAX(0, [defaults integerForKey:MixKey]));
        // Do not block the renderer on compressed-file preparation.
        dispatch_async(_queue, ^{
            self->_radio = [RadioChannel new];
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
    [_radio clear];
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

- (void)radio:(NSString *)text {
    dispatch_async(_queue, ^{
        if (self->_mix == 2 || !self->_active || self->_interrupted || !self->_flying) return;
        [self->_radio transmit:text];
    });
}

- (void)clearRadio { dispatch_async(_queue, ^{ [self->_radio clear]; }); }
- (BOOL)radioPlaying {
    __block BOOL value; dispatch_sync(_queue, ^{ value = self->_radio.playing; }); return value;
}
- (BOOL)radioPending {
    __block BOOL value; dispatch_sync(_queue, ^{ value = self->_radio.pending; }); return value;
}
- (NSString *)radioText {
    __block NSString *value; dispatch_sync(_queue, ^{ value = self->_radio.text; }); return value;
}

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
            [self->_radio clear];
            self->_flying = flying;
            self->_alive = NO; // Await fresh ship state after a mission transition.
        }
        if (!self->_active || self->_interrupted || self->_mix == 2) return;
        [self->_radio update];
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
