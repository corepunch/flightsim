#import "NetTransport.h"
#import "Cvar.h"
#import <QuartzCore/QuartzCore.h>
#include <netdb.h>
#include <arpa/inet.h>

@implementation NetAddress {
    NSData *_sa;
}

+ (instancetype)loopback:(int)port {
    NetAddress *a = [NetAddress new];
    a->_isLoopback = YES;
    a->_port = port;
    return a;
}

+ (instancetype)addressWithSockaddr:(const void *)sa length:(unsigned)len {
    NetAddress *a = [NetAddress new];
    a->_sa = [NSData dataWithBytes:sa length:len];
    a->_port = ntohs(((const struct sockaddr_in *)sa)->sin_port);
    return a;
}

+ (instancetype)addressWithString:(NSString *)s port:(int)defaultPort {
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!s.length || [s isEqualToString:@"loopback"] || [s isEqualToString:@"localhost:loopback"]) return [self loopback:1];
    NSString *host = s;
    int port = defaultPort;
    NSRange colon = [s rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound) {
        host = [s substringToIndex:colon.location];
        port = [s substringFromIndex:colon.location + 1].intValue ?: defaultPort;
    }
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(host.UTF8String, NULL, &hints, &res) != 0 || !res) return nil;
    struct sockaddr_in sin = *(struct sockaddr_in *)res->ai_addr;
    freeaddrinfo(res);
    sin.sin_port = htons((uint16_t)port);
    return [self addressWithSockaddr:&sin length:sizeof sin];
}

- (NSData *)sockaddr { return _sa; }

- (NSString *)string {
    if (_isLoopback) return [NSString stringWithFormat:@"loopback:%d", _port];
    const struct sockaddr_in *sin = _sa.bytes;
    char buf[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof buf);
    return [NSString stringWithFormat:@"%s:%d", buf, ntohs(sin->sin_port)];
}

- (NSString *)description { return self.string; }

- (BOOL)isEqual:(id)o {
    if (![o isKindOfClass:[NetAddress class]]) return NO;
    NetAddress *b = o;
    if (_isLoopback || b->_isLoopback) return _isLoopback == b->_isLoopback && _port == b->_port;
    const struct sockaddr_in *x = _sa.bytes, *y = b->_sa.bytes;
    return x->sin_addr.s_addr == y->sin_addr.s_addr && x->sin_port == y->sin_port;
}

- (NSUInteger)hash {
    if (_isLoopback) return (NSUInteger)_port;
    const struct sockaddr_in *x = _sa.bytes;
    return x->sin_addr.s_addr ^ ((NSUInteger)x->sin_port << 16);
}

- (id)copyWithZone:(NSZone *)zone { return self; }

@end

#pragma mark - Loopback

static Cvar *gLoss, *gLatency;

@interface LoopPacket : NSObject
@property (nonatomic, strong) NSData *data;
@property (nonatomic) double deliverAt;
@end
@implementation LoopPacket
@end

@implementation LoopbackTransport {
    int _port;
    NSMutableArray<LoopPacket *> *_queue;
}

+ (instancetype)side:(int)port {
    static LoopbackTransport *sides[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int i = 0; i < 2; i++) {
            sides[i] = [LoopbackTransport new];
            sides[i]->_port = i;
            sides[i]->_queue = [NSMutableArray array];
        }
        gLoss = [Cvar get:@"net_loss" defaultValue:@"0" flags:0 help:@"Loopback: fraction of packets dropped (0..1)"];
        gLatency = [Cvar get:@"net_latency" defaultValue:@"0" flags:0 help:@"Loopback: simulated round trip, ms"];
    });
    return sides[port & 1];
}

- (void)send:(NSData *)packet to:(NetAddress *)to {
    if (!to.isLoopback) return;
    float loss = gLoss.value;
    if (loss > 0 && arc4random_uniform(10000) < (uint32_t)(loss * 10000)) return;
    LoopbackTransport *dest = [LoopbackTransport side:to.port];
    LoopPacket *p = [LoopPacket new];
    p.data = [packet copy];
    // One-way delay is half the simulated round trip.
    p.deliverAt = CACurrentMediaTime() + gLatency.value / 1000.0 * 0.5;
    @synchronized (dest->_queue) { [dest->_queue addObject:p]; }
}

- (NSData *)receiveFrom:(NetAddress *__autoreleasing *)from {
    @synchronized (_queue) {
        LoopPacket *p = _queue.firstObject;
        if (!p || p.deliverAt > CACurrentMediaTime()) return nil;
        [_queue removeObjectAtIndex:0];
        *from = [NetAddress loopback:_port ^ 1];
        return p.data;
    }
}

@end
