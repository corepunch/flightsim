#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import "Audio.h"
#import "UI.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "Audio check failed at line %d: %s\n", __LINE__, #c); return EXIT_FAILURE; } } while (0)

static void Drain(GameAudio *audio) {
    dispatch_queue_t queue = [audio valueForKey:@"queue"];
    dispatch_sync(queue, ^{});
}

static void Frames(GameAudio *audio, BOOL flying, int count) {
    for (int i = 0; i < count; i++) [audio frame:1.0f / 60 flying:flying];
    Drain(audio);
}

static int Checks(NSString *output) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:0 forKey:@"SpaceFight.audioMix"];
    NSURL *manifestURL = [NSBundle.mainBundle URLForResource:@"manifest" withExtension:@"json" subdirectory:@"Audio"];
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:manifestURL] options:0 error:nil];
    CHECK([manifest[@"assets"] count] == 14);
    // Decode every frame, not just the header; reject silence and corrupt/truncated downloads.
    for (NSDictionary *asset in manifest[@"assets"]) {
        @autoreleasepool {
            NSURL *url = [manifestURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:asset[@"file"]];
            NSError *error;
            AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&error];
            CHECK(file && !error);
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:4096];
            CHECK(buffer.floatChannelData);
            double energy = 0, peak = 0, onset = -1;
            AVAudioFramePosition frames = 0;
            while (file.framePosition < file.length) {
                CHECK([file readIntoBuffer:buffer error:&error] && !error && buffer.frameLength > 0);
                for (AVAudioFrameCount i = 0; i < buffer.frameLength; i++) {
                    for (AVAudioChannelCount ch = 0; ch < buffer.format.channelCount; ch++) {
                        double s = buffer.floatChannelData[ch][i];
                        CHECK(isfinite(s));
                        energy += s * s; peak = MAX(peak, fabs(s));
                        if (onset < 0 && fabs(s) > 0.01) onset = (frames + i) / buffer.format.sampleRate;
                    }
                }
                frames += buffer.frameLength;
            }
            double seconds = frames / buffer.format.sampleRate;
            double rms = sqrt(energy / (frames * buffer.format.channelCount));
            CHECK(fabs(seconds - [asset[@"durationSeconds"] doubleValue]) < 0.15);
            CHECK(rms > 0.002 && peak < 1.1);
            printf("Decoded %s: %.2fs, peak %.3f, RMS %.3f, onset %.3fs\n", [asset[@"file"] UTF8String], seconds, peak, rms, onset);
        }
    }

    GameAudio *audio = GameAudio.shared;
    Drain(audio);
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:NSApp];
    Frames(audio, NO, 90);
    NSArray<NSArray<AVAudioPlayer *> *> *music = [audio valueForKey:@"music"];
    NSDictionary<NSString *, NSArray<AVAudioPlayer *> *> *effects = [audio valueForKey:@"effects"];
    AVAudioPlayer *engine = [audio valueForKey:@"engine"], *boost = [audio valueForKey:@"boost"];
    CHECK(music.count == 2 && effects.count == 11 && engine && boost);
    CHECK(music[0][0].playing && music[0][0].volume > 0.25 && !music[1][0].playing);
    [audio play:@"laser" gain:0.5 pan:-0.7]; Drain(audio);
    AVAudioPlayer *laser = effects[@"laser"][0];
    CHECK(laser.playing && fabs(laser.pan + 0.7) < 0.01 && laser.volume > 0);

    Frames(audio, YES, 1);
    [audio shipThrottle:1 boost:YES alive:YES];
    Frames(audio, YES, 180);
    CHECK(music[1][0].playing && !music[0][0].playing);
    CHECK(engine.playing && engine.volume > 0.20 && engine.rate > 1.1 && boost.playing);
    Frames(audio, NO, 180);
    CHECK(!engine.playing && !boost.playing && !music[1][0].playing);

    // Force a boundary so the prepared second music voice must take over.
    dispatch_queue_t queue = [audio valueForKey:@"queue"];
    dispatch_sync(queue, ^{ music[0][0].currentTime = music[0][0].duration - 1; });
    Frames(audio, NO, 1);
    CHECK(music[0][1].playing && music[0][1].volume > 0.10);
    dispatch_sync(queue, ^{ music[0][0].currentTime = music[0][0].duration - 0.03; });
    Frames(audio, NO, 1);
    CHECK(!music[0][0].playing && music[0][1].playing);

    [audio cycleMix]; Frames(audio, NO, 5);
    CHECK([defaults integerForKey:@"SpaceFight.audioMix"] == 1 && !music[0][1].playing);
    [audio play:@"ui-confirm"]; Drain(audio);
    CHECK(effects[@"ui-confirm"][0].playing);
    [audio cycleMix]; Drain(audio);
    [audio play:@"explosion"]; Frames(audio, YES, 5);
    CHECK([defaults integerForKey:@"SpaceFight.audioMix"] == 2);
    for (NSArray *voices in effects.allValues) for (AVAudioPlayer *p in voices) CHECK(!p.playing);
    [audio cycleMix]; Frames(audio, NO, 90);
    CHECK(music[0][1].playing);
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidResignActiveNotification object:NSApp];
    Drain(audio);
    CHECK(!music[0][1].playing && !engine.playing);
    [audio play:@"impact"]; Drain(audio);
    CHECK(!effects[@"impact"][0].playing);
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:NSApp];
    Frames(audio, NO, 1);
    CHECK(music[0][1].playing);

    // Exercise the actual keyboard path to the new setting and check compact layouts.
    for (NSValue *value in @[[NSValue valueWithSize:NSMakeSize(1280, 800)],
                             [NSValue valueWithSize:NSMakeSize(640, 360)],
                             [NSValue valueWithSize:NSMakeSize(390, 844)]]) {
        CGSize size = value.sizeValue;
        MainMenu *menu = [[MainMenu alloc] initWithSize:size];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){.size=size} styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered defer:NO];
        SKView *view = [[SKView alloc] initWithFrame:(NSRect){.size=size}];
        window.contentView = view;
        [window orderBack:nil];
        [view presentScene:menu];
        for (int i = 0; i < 4; i++) [menu handle:InputActionDown];
        NSInteger previous = [defaults integerForKey:@"SpaceFight.audioMix"];
        [menu handle:InputActionConfirm]; Drain(audio);
        CHECK([defaults integerForKey:@"SpaceFight.audioMix"] == (previous + 1) % 3);
        SKNode *root = [menu valueForKey:@"root"];
        for (SKNode *node in root.children) if ([node isKindOfClass:SKLabelNode.class]) {
            CHECK(CGRectGetMinY(node.frame) >= 0 && CGRectGetMaxY(node.frame) <= size.height + 1);
        }
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.6];
        while (until.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:until];
        SKTexture *texture = [view textureFromNode:menu crop:(CGRect){.size=size}];
        CHECK(texture.CGImage);
        NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithCGImage:texture.CGImage];
        NSString *name = [NSString stringWithFormat:@"menu-%.0fx%.0f.png", size.width, size.height];
        [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[output stringByAppendingPathComponent:name] atomically:YES];
        [window orderOut:nil];
    }
    [audio cycleMix]; Drain(audio); // Silence the check app before exit.
    puts("PASS: audio assets, playback, crossfades, mute, lifecycle and menu setting");
    return EXIT_SUCCESS;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        CHECK(argc == 2);
        return Checks(@(argv[1]));
    }
}
