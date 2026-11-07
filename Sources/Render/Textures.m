#import "Render.h"
#import "Common.h"
#import <ImageIO/ImageIO.h>

@implementation RenderTextures

static NSMutableDictionary<NSString *, PlatformImage *> *textures;
static NSUInteger decodedBytes;
static Cvar *textureSize;

+ (void)initialize {
    if (self != RenderTextures.class) return;
    textures = [NSMutableDictionary dictionary];
    textureSize = [Cvar get:@"r_textureSize" defaultValue:@"512" flags:CVAR_ARCHIVE
                      help:@"Maximum 3D texture edge in pixels; 0 uses source size (restart required)"];
}

+ (id)contentsOfURL:(NSURL *)url sRGB:(BOOL)sRGB {
    if (!url) return nil;
    @synchronized (self) {
        NSString *key = [NSString stringWithFormat:@"%@|%d", url.absoluteString, sRGB];
        PlatformImage *texture = textures[key];
        if (texture) return texture;
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url,
            (__bridge CFDictionaryRef)@{ (__bridge id)kCGImageSourceShouldCache: @NO });
        if (!source) return url;
        NSUInteger limit = textureSize.integer > 0 ? MAX(128, MIN(4096, textureSize.integer)) : 0;
        CGImageRef image = limit ? CGImageSourceCreateThumbnailAtIndex(source, 0,
            (__bridge CFDictionaryRef)@{
                (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @(limit),
                (__bridge id)kCGImageSourceShouldCacheImmediately: @YES,
            }) : CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!image) return url;
        // Let SceneKit apply each material channel's colour/data semantics.
        // Supplying raw Metal textures here changes that interpretation.
#if TARGET_OS_IOS
        texture = [UIImage imageWithCGImage:image];
#else
        texture = [[NSImage alloc] initWithCGImage:image size:NSZeroSize];
#endif
        decodedBytes += CGImageGetBytesPerRow(image) * CGImageGetHeight(image);
        CGImageRelease(image);
        textures[key] = texture;
        return texture;
    }
}

+ (void)printStats {
    @synchronized (self) {
        NSLog(@"Textures: %lu shared images, %.1f MiB decoded, maximum edge %d px", (unsigned long)textures.count,
              decodedBytes / 1048576.0, textureSize.integer);
    }
}
@end
