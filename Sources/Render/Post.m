#import "Render.h"

// The technique is built from a dictionary (the format is documented in SCNTechnique.h):
// the scene pass draws into a texture, four quad passes blur the bright parts down to a
// quarter and a sixteenth of the drawable, and the final pass composes them on screen.
// A scene in scene-linear light gets one more small pass, the streak. Targets without a format
// take the drawable's, so a display-ready scene round-trips losslessly; a scene in
// scene-linear light takes half-float targets, which hold what is brighter than white.

@implementation PostProcess

+ (NSDictionary *)quadPass:(NSString *)fragment inputs:(NSDictionary *)inputs output:(NSString *)output {
    return @{ @"draw": @"DRAW_QUAD",
              @"metalVertexShader": @"postQuadVertex",
              @"metalFragmentShader": fragment,
              @"inputs": inputs,
              @"outputs": @{ @"color": output },
              @"colorStates": @{ @"clear": @YES } };
}

+ (NSDictionary *)target:(float)scale hdr:(BOOL)hdr {
    NSMutableDictionary *target = [@{ @"type": @"color" } mutableCopy];
    if (scale != 1) target[@"scaleFactor"] = @(scale);
    if (hdr) target[@"format"] = @"rgba16f";
    return target;
}

+ (SCNTechnique *)techniqueWithDevice:(id<MTLDevice>)device shaderDirectory:(NSURL *)directory settings:(PostSettings)settings {
    NSURL *url = [directory URLByAppendingPathComponent:@"Post.metal"];
    NSString *body = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
    if (!body) { NSLog(@"Post: missing %@", url.path); return nil; }
    NSString *source = [NSString stringWithFormat:
        @"constant bool kHDR = %@;\nconstant float kBloom = %g;\nconstant float kBloomKnee = %g;\n"
         "constant float kVignette = %g;\nconstant float kGrade = %g;\n%@",
        settings.hdr ? @"true" : @"false", settings.bloom, settings.bloomKnee, settings.vignette, settings.grade, body];
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) { NSLog(@"Post: shader compile failed: %@", error); return nil; }

    BOOL hdr = settings.hdr;
    NSDictionary *passes = @{
        @"scene": @{ @"draw": @"DRAW_SCENE",
                     @"outputs": @{ @"color": @"scene", @"depth": @"DEPTH" },
                     @"colorStates": @{ @"clear": @YES, @"clearColor": @"sceneBackground" } },
        @"bright": [self quadPass:@"postBright" inputs:@{ @"sceneMap": @"scene" } output:@"glowA"],
        @"glowH": [self quadPass:@"postBlurH" inputs:@{ @"bloomMap": @"glowA" } output:@"glowB"],
        @"glowV": [self quadPass:@"postBlurV" inputs:@{ @"bloomMap": @"glowB" } output:@"glowA"],
        @"veilH": [self quadPass:hdr ? @"postVeilH" : @"postBlurH" inputs:@{ @"bloomMap": @"glowA" } output:@"veilB"],
        @"veilV": [self quadPass:@"postBlurV" inputs:@{ @"bloomMap": @"veilB" } output:@"veilA"],
        // The streak goes into the veil's scratch target, which the blur has finished
        // with. A display-ready frame has none, and its final pass never reads the slot.
        @"streak": [self quadPass:@"postStreak" inputs:@{ @"bloomMap": @"veilA" } output:@"veilB"],
        @"final": [self quadPass:@"postFinal" inputs:@{ @"sceneMap": @"scene", @"glowMap": @"glowA", @"veilMap": @"veilA",
                                                         @"streakMap": hdr ? @"veilB" : @"veilA" } output:@"COLOR"],
    };
    NSDictionary *targets = @{
        @"scene": [self target:1 hdr:hdr],
        @"glowA": [self target:0.25f hdr:hdr],
        @"glowB": [self target:0.25f hdr:hdr],
        @"veilA": [self target:0.0625f hdr:hdr],
        @"veilB": [self target:0.0625f hdr:hdr],
    };
    SCNTechnique *technique = [SCNTechnique techniqueWithDictionary:@{
        @"sequence": hdr ? @[ @"scene", @"bright", @"glowH", @"glowV", @"veilH", @"veilV", @"streak", @"final" ]
                         : @[ @"scene", @"bright", @"glowH", @"glowV", @"veilH", @"veilV", @"final" ],
        @"passes": passes,
        @"targets": targets,
    }];
    technique.library = library;
    return technique;
}

@end
