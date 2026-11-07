#import "Render.h"
#import "Common.h"
#import <ImageIO/ImageIO.h>

@implementation RenderTextures

static NSMutableDictionary<NSString *, id<MTLTexture>> *textures;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static NSUInteger gpuBytes;
static Cvar *textureSize;

+ (void)initialize {
    if (self != RenderTextures.class) return;
    textures = [NSMutableDictionary dictionary];
    textureSize = [Cvar get:@"r_textureSize" defaultValue:@"512" flags:CVAR_ARCHIVE
                      help:@"Maximum 3D texture edge in pixels; 0 uses source size (restart required)"];
}

+ (void)useDevice:(id<MTLDevice>)d {
    @synchronized (self) {
        if (!d || d == device) return;
        device = d;
        queue = [d newCommandQueue];
    }
}

// The pixel format carries the colour space, so SceneKit samples colour maps
// through the sRGB curve and reads data maps as they are. MetalKit's loader
// ignores its sRGB option here, hence the explicit path.
static id<MTLTexture> TextureFromImage(CGImageRef image, BOOL sRGB, NSString *label) {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    NSMutableData *pixels = [NSMutableData dataWithLength:w * h * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, w * 4, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        sRGB ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:YES];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:d];
    texture.label = label;
    [texture replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:w * 4];
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
    [blit generateMipmapsForTexture:texture];
    [blit endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    return texture;
}

+ (id)contentsOfURL:(NSURL *)url sRGB:(BOOL)sRGB {
    if (!url) return nil;
    @synchronized (self) {
        NSString *key = [NSString stringWithFormat:@"%@|%d", url.absoluteString, sRGB];
        id<MTLTexture> texture = textures[key];
        if (texture) return texture;
        if (!device) [self useDevice:MTLCreateSystemDefaultDevice()];
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
        // The texture is the only copy that stays: the decoded image goes as
        // soon as its pixels and mip chain are on the GPU.
        texture = TextureFromImage(image, sRGB, url.lastPathComponent);
        CGImageRelease(image);
        if (!texture) return url;
        gpuBytes += texture.width * texture.height * 4 * 4 / 3;   // RGBA8 and its mip chain
        textures[key] = texture;
        return texture;
    }
}

+ (void)printStats {
    @synchronized (self) {
        NSLog(@"Textures: %lu shared, %.1f MiB on the GPU, no decoded copies, maximum edge %d px",
              (unsigned long)textures.count, gpuBytes / 1048576.0, textureSize.integer);
    }
}
@end
