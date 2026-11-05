#import <Cocoa/Cocoa.h>
#import <SceneKit/SceneKit.h>
#import "Render.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); return EXIT_FAILURE; } } while (0)

static CGImageRef Render(SKView *view, SKScene *scene) {
    [view presentScene:scene];
    return [[view textureFromNode:scene crop:CGRectMake(0, 0, scene.size.width, scene.size.height)] CGImage];
}

static NSData *Pixels(CGImageRef image) {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    NSMutableData *data = [NSMutableData dataWithLength:w * h * 4];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(data.mutableBytes, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return data;
}

static void WriteImage(CGImageRef image, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

static BOOL Black(NSData *data) {
    const uint8_t *p = data.bytes;
    for (NSUInteger i = 0; i < data.length; i += 4)
        if (p[i] || p[i + 1] || p[i + 2]) return NO;
    return YES;
}

static CGImageRef Composite(SCNRenderer *renderer, CGSize size) {
    NSImage *image = [renderer snapshotAtTime:0 withSize:size antialiasingMode:SCNAntialiasingModeNone];
    return [image CGImageForProposedRect:NULL context:nil hints:nil];
}

static NSImage *Checkerboard(void) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, 256, 256, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) {
        BOOL light = (x + y) % 2;
        CGContextSetRGBFillColor(ctx, light ? 0.55 : 0.16, light ? 0.48 : 0.24, light ? 0.32 : 0.36, 1);
        CGContextFillRect(ctx, CGRectMake(x * 32, y * 32, 32, 32));
    }
    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    NSImage *image = [[NSImage alloc] initWithCGImage:cg size:NSZeroSize];
    CGImageRelease(cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return image;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        CHECK(argc == 2);
        NSString *output = @(argv[1]);
        for (NSValue *value in @[[NSValue valueWithSize:NSMakeSize(1280, 720)],
                                 [NSValue valueWithSize:NSMakeSize(852, 393)],
                                 [NSValue valueWithSize:NSMakeSize(1194, 834)]]) {
            CGSize size = value.sizeValue;
            SKView *view = [[SKView alloc] initWithFrame:(NSRect){ .size = size }];
            SKScene *scene = [SKScene sceneWithSize:size];
            scene.backgroundColor = SKColor.blackColor;
            SKSpriteNode *background = [SKSpriteNode spriteNodeWithColor:SKColor.blackColor size:size];
            background.anchorPoint = CGPointZero;
            [scene addChild:background];
            LensFlare *flare = [LensFlare new];
            [scene addChild:flare];
            CGPoint source = CGPointMake(size.width / 2, size.height / 2);
            for (int i = 0; i < 60; i++) [flare updateSource:source visibility:1 viewport:size deltaTime:1.0 / 60];
            CGImageRef image = Render(view, scene);
            CHECK(image);
            NSData *data = Pixels(image);
            size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
            const uint8_t *pixels = data.bytes;
            const uint8_t *core = pixels + ((h / 2) * w + w / 2) * 4;
            CHECK(core[0] > 40 && core[1] > 25); // A shader compile failure produces no light.
            CGFloat scale = w / size.width;
            const uint8_t *shoulder = core + (int)(size.height * 0.12 * scale) * 4;
            CHECK(shoulder[2] > shoulder[0] && shoulder[2] > 4);
            // The streak must taper away, with no rectangular quad boundary.
            const uint8_t *tail = core + (int)(size.height * 0.80 * scale) * 4;
            if (size.height * 0.80 < size.width / 2) CHECK(tail[2] < shoulder[2] / 2);
            for (size_t x = 0; x < w; x++) {
                CHECK(pixels[x * 4] == 0 && pixels[x * 4 + 1] == 0 && pixels[x * 4 + 2] == 0);
                size_t last = ((h - 1) * w + x) * 4;
                CHECK(pixels[last] == 0 && pixels[last + 1] == 0 && pixels[last + 2] == 0);
            }
            WriteImage(image, [output stringByAppendingPathComponent:[NSString stringWithFormat:@"flare-%.0fx%.0f.png", size.width, size.height]]);
            NSUInteger nodes = flare.children.count;
            [flare updateSource:source visibility:0 viewport:size deltaTime:1.0 / 60];
            CHECK(flare.hidden && Black(Pixels(Render(view, scene)))); // No afterglow through an occluder.
            [flare updateSource:CGPointMake(-10, source.y) visibility:1 viewport:size deltaTime:1.0 / 60];
            CHECK(flare.hidden && Black(Pixels(Render(view, scene))));
            [flare updateSource:CGPointMake(NAN, source.y) visibility:1 viewport:size deltaTime:1.0 / 60];
            CHECK(flare.hidden);

            for (int i = 0; i < 30; i++) [flare updateSource:source visibility:1 viewport:size deltaTime:1.0 / 30];
            CGFloat at30 = flare.alpha;
            [flare updateSource:source visibility:0 viewport:size deltaTime:1.0 / 30];
            for (int i = 0; i < 120; i++) [flare updateSource:source visibility:1 viewport:size deltaTime:1.0 / 120];
            CHECK(fabs(at30 - flare.alpha) < 0.00001 && flare.children.count == nodes);
            CGFloat full = flare.alpha;
            [flare updateSource:CGPointMake(size.height * 0.02, source.y) visibility:1 viewport:size deltaTime:1.0 / 60];
            CHECK(flare.alpha < full * 0.2); // Smooth edge attenuation uses viewport proportions.

            // A second render exercises dispersed reflections away from the optical centre.
            source = CGPointMake(size.width * 0.68, size.height * 0.60);
            for (int i = 0; i < 60; i++) [flare updateSource:source visibility:1 viewport:size deltaTime:1.0 / 60];
            WriteImage(Render(view, scene), [output stringByAppendingPathComponent:[NSString stringWithFormat:@"flare-offset-%.0fx%.0f.png", size.width, size.height]]);

            // Exercise the actual game pipeline: SpriteKit flattens a
            // transparent HUD before SceneKit composites it over the world.
            // A black-only SpriteKit test cannot detect opaque black quads.
            [background removeFromParent];
            scene.backgroundColor = SKColor.clearColor;
            SCNRenderer *renderer = [SCNRenderer rendererWithDevice:MTLCreateSystemDefaultDevice() options:nil];
            SCNScene *world = [SCNScene scene];
            world.background.contents = Checkerboard();
            SCNNode *camera = [SCNNode node];
            camera.camera = [SCNCamera camera];
            [world.rootNode addChildNode:camera];
            renderer.scene = world;
            renderer.pointOfView = camera;
            CGImageRef baseline = Composite(renderer, size);
            CHECK(baseline);
            NSData *before = Pixels(baseline);
            renderer.overlaySKScene = scene;
            CGImageRef combined = Composite(renderer, size);
            CHECK(combined && CGImageGetWidth(combined) == CGImageGetWidth(baseline));
            NSData *after = Pixels(combined);
            CHECK(before.length == after.length);
            const uint8_t *b = before.bytes, *a = after.bytes;
            NSUInteger darker = 0;
            for (NSUInteger i = 0; i < before.length; i += 4) {
                for (int c = 0; c < 3; c++) if ((int)a[i+c] + 2 < b[i+c]) darker++;
            }
            if (darker) fprintf(stderr, "Compositing darkened %lu background channels at %.0fx%.0f\n", (unsigned long)darker, size.width, size.height);
            CHECK(darker == 0); // Lens flare adds light and never covers the world.
            WriteImage(combined, [output stringByAppendingPathComponent:[NSString stringWithFormat:@"composite-%.0fx%.0f.png", size.width, size.height]]);
            [flare updateSource:source visibility:0 viewport:size deltaTime:1.0 / 60];
            CHECK([before isEqualToData:Pixels(Composite(renderer, size))]);
            // Device shader failure falls back to an empty texture, never a quad.
            for (SKSpriteNode *sprite in flare.children) sprite.shader = nil;
            for (int i = 0; i < 60; i++) [flare updateSource:source visibility:1 viewport:size deltaTime:1.0 / 60];
            CHECK([before isEqualToData:Pixels(Composite(renderer, size))]);
        }
        puts("PASS: rendered flare colour/falloff, SceneKit overlay preserves scenery, transparent borders, occlusion, offscreen rejection, exposure at 30/120 Hz, stable node count; desktop, iPhone and iPad sizes.");
    }
    return EXIT_SUCCESS;
}
