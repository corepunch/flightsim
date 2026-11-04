#pragma once
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
typedef UIImage PlatformImage;
typedef UIFont PlatformFont;
#else
#import <AppKit/AppKit.h>
typedef NSImage PlatformImage;
typedef NSFont PlatformFont;
#endif

static inline PlatformImage *PlatformImageFromCGImage(CGImageRef image) {
#if TARGET_OS_IOS
    return [UIImage imageWithCGImage:image];
#else
    return [[NSImage alloc] initWithCGImage:image size:NSZeroSize];
#endif
}

static inline PlatformImage *PlatformDrawImage(CGSize size, void (^draw)(CGContextRef, CGRect)) {
#if TARGET_OS_IOS
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        draw(context.CGContext, CGRectMake(0, 0, size.width, size.height));
    }];
#else
    return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        draw(NSGraphicsContext.currentContext.CGContext, rect);
        return YES;
    }];
#endif
}
