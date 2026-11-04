#import <Foundation/Foundation.h>
#import <simd/simd.h>

// Little-endian byte writer/reader for packets. Reads past the end return
// zero and set `overflow`, so a truncated packet can't crash the parser;
// callers check `overflow` once at the end.
@interface MsgWriter : NSObject
@property (nonatomic, readonly) NSMutableData *data;
@property (nonatomic, readonly) NSUInteger length;
- (void)u8:(uint8_t)v;
- (void)u16:(uint16_t)v;
- (void)u32:(uint32_t)v;
- (void)u64:(uint64_t)v;
- (void)i16:(int16_t)v;
- (void)f32:(float)v;
- (void)f64:(double)v;
- (void)vec3:(simd_float3)v;
- (void)quat:(simd_quatf)q;     // full precision
- (void)string:(NSString *)s;   // u16 length + UTF-8
- (void)bytes:(NSData *)d;
@end

@interface MsgReader : NSObject
- (instancetype)initWithData:(NSData *)data;
@property (nonatomic, readonly) BOOL overflow;
@property (nonatomic, readonly) NSUInteger remaining;
- (uint8_t)u8;
- (uint16_t)u16;
- (uint32_t)u32;
- (uint64_t)u64;
- (int16_t)i16;
- (float)f32;
- (double)f64;
- (simd_float3)vec3;
- (simd_quatf)quat;
- (NSString *)string;
- (NSData *)bytes:(NSUInteger)n;
- (NSData *)rest;
@end
