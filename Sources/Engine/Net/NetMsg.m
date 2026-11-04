#import "NetMsg.h"
#include <libkern/OSByteOrder.h>

@implementation MsgWriter

- (instancetype)init {
    if ((self = [super init])) _data = [NSMutableData dataWithCapacity:1400];
    return self;
}

- (NSUInteger)length { return _data.length; }
- (void)u8:(uint8_t)v { [_data appendBytes:&v length:1]; }
- (void)u16:(uint16_t)v { v = OSSwapHostToLittleInt16(v); [_data appendBytes:&v length:2]; }
- (void)u32:(uint32_t)v { v = OSSwapHostToLittleInt32(v); [_data appendBytes:&v length:4]; }
- (void)u64:(uint64_t)v { v = OSSwapHostToLittleInt64(v); [_data appendBytes:&v length:8]; }
- (void)i16:(int16_t)v { [self u16:(uint16_t)v]; }
- (void)f32:(float)v { uint32_t u; memcpy(&u, &v, 4); [self u32:u]; }
- (void)f64:(double)v { uint64_t u; memcpy(&u, &v, 8); [self u64:u]; }
- (void)vec3:(simd_float3)v { [self f32:v.x]; [self f32:v.y]; [self f32:v.z]; }
- (void)quat:(simd_quatf)q { [self f32:q.vector.x]; [self f32:q.vector.y]; [self f32:q.vector.z]; [self f32:q.vector.w]; }

- (void)string:(NSString *)s {
    NSData *d = [s ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger n = MIN(d.length, 0xFFFF);
    [self u16:(uint16_t)n];
    [_data appendBytes:d.bytes length:n];
}

- (void)bytes:(NSData *)d { [_data appendData:d]; }

@end

@implementation MsgReader {
    NSData *_data;
    NSUInteger _pos;
}

- (instancetype)initWithData:(NSData *)data {
    if ((self = [super init])) _data = data;
    return self;
}

- (NSUInteger)remaining { return _pos < _data.length ? _data.length - _pos : 0; }

- (BOOL)read:(void *)out length:(NSUInteger)n {
    if (_pos + n > _data.length) {
        _overflow = YES;
        memset(out, 0, n);
        _pos = _data.length;
        return NO;
    }
    memcpy(out, (const uint8_t *)_data.bytes + _pos, n);
    _pos += n;
    return YES;
}

- (uint8_t)u8 { uint8_t v; [self read:&v length:1]; return v; }
- (uint16_t)u16 { uint16_t v; [self read:&v length:2]; return OSSwapLittleToHostInt16(v); }
- (uint32_t)u32 { uint32_t v; [self read:&v length:4]; return OSSwapLittleToHostInt32(v); }
- (uint64_t)u64 { uint64_t v; [self read:&v length:8]; return OSSwapLittleToHostInt64(v); }
- (int16_t)i16 { return (int16_t)[self u16]; }
- (float)f32 { uint32_t u = [self u32]; float v; memcpy(&v, &u, 4); return v; }
- (double)f64 { uint64_t u = [self u64]; double v; memcpy(&v, &u, 8); return v; }
- (simd_float3)vec3 { float x = [self f32], y = [self f32], z = [self f32]; return simd_make_float3(x, y, z); }
- (simd_quatf)quat { float x = [self f32], y = [self f32], z = [self f32], w = [self f32]; return simd_quaternion(x, y, z, w); }

- (NSString *)string {
    NSData *d = [self bytes:[self u16]];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
}

- (NSData *)bytes:(NSUInteger)n {
    if (_pos + n > _data.length) { _overflow = YES; _pos = _data.length; return [NSData data]; }
    NSData *d = [_data subdataWithRange:NSMakeRange(_pos, n)];
    _pos += n;
    return d;
}

- (NSData *)rest { return [self bytes:self.remaining]; }

@end
