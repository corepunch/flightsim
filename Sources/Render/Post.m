#import "Render.h"

// The technique is built from a dictionary (the format is documented in SCNTechnique.h):
// the scene pass draws into a texture, four quad passes blur the bright parts down to a
// quarter and a sixteenth of the drawable, and the final pass composes them on screen.
// Targets without a format take the drawable's, so the scene round-trips losslessly.

@implementation PostProcess

+ (NSDictionary *)quadPass:(NSString *)fragment inputs:(NSDictionary *)inputs output:(NSString *)output {
    return @{ @"draw": @"DRAW_QUAD",
              @"metalVertexShader": @"postQuadVertex",
              @"metalFragmentShader": fragment,
              @"inputs": inputs,
              @"outputs": @{ @"color": output },
              @"colorStates": @{ @"clear": @YES } };
}

+ (SCNTechnique *)techniqueWithDevice:(id<MTLDevice>)device shaderDirectory:(NSURL *)directory settings:(PostSettings)settings {
    NSURL *url = [directory URLByAppendingPathComponent:@"Post.metal"];
    NSString *body = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
    if (!body) { NSLog(@"Post: missing %@", url.path); return nil; }
    NSString *source = [NSString stringWithFormat:
        @"constant float kBloom = %g;\nconstant float kBloomKnee = %g;\nconstant float kVignette = %g;\nconstant float kGrade = %g;\n%@",
        settings.bloom, settings.bloomKnee, settings.vignette, settings.grade, body];
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) { NSLog(@"Post: shader compile failed: %@", error); return nil; }

    NSDictionary *passes = @{
        @"scene": @{ @"draw": @"DRAW_SCENE",
                     @"outputs": @{ @"color": @"scene", @"depth": @"DEPTH" },
                     @"colorStates": @{ @"clear": @YES, @"clearColor": @"sceneBackground" } },
        @"bright": [self quadPass:@"postBright" inputs:@{ @"sceneMap": @"scene" } output:@"glowA"],
        @"glowH": [self quadPass:@"postBlurH" inputs:@{ @"bloomMap": @"glowA" } output:@"glowB"],
        @"glowV": [self quadPass:@"postBlurV" inputs:@{ @"bloomMap": @"glowB" } output:@"glowA"],
        @"veilH": [self quadPass:@"postBlurH" inputs:@{ @"bloomMap": @"glowA" } output:@"veilB"],
        @"veilV": [self quadPass:@"postBlurV" inputs:@{ @"bloomMap": @"veilB" } output:@"veilA"],
        @"final": [self quadPass:@"postFinal" inputs:@{ @"sceneMap": @"scene", @"glowMap": @"glowA", @"veilMap": @"veilA" } output:@"COLOR"],
    };
    NSDictionary *targets = @{
        @"scene": @{ @"type": @"color" },
        @"glowA": @{ @"type": @"color", @"scaleFactor": @0.25 },
        @"glowB": @{ @"type": @"color", @"scaleFactor": @0.25 },
        @"veilA": @{ @"type": @"color", @"scaleFactor": @0.0625 },
        @"veilB": @{ @"type": @"color", @"scaleFactor": @0.0625 },
    };
    SCNTechnique *technique = [SCNTechnique techniqueWithDictionary:@{
        @"sequence": @[ @"scene", @"bright", @"glowH", @"glowV", @"veilH", @"veilV", @"final" ],
        @"passes": passes,
        @"targets": targets,
    }];
    technique.library = library;
    return technique;
}

@end
