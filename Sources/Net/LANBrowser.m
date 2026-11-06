#import "Net.h"
#import <QuartzCore/QuartzCore.h>
#include <netinet/in.h>

static NSString *const LANServiceType = @"_kestrel._udp.";

@interface LANAdvertisement () <NSNetServiceDelegate>
@property (atomic, readwrite) BOOL failed;
@end

@implementation LANAdvertisement {
    NSNetService *_service;
}
- (instancetype)initWithName:(NSString *)name port:(int)port {
    if ((self = [super init])) {
        __weak LANAdvertisement *weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            LANAdvertisement *owner = weak;
            if (!owner) return;
            owner->_service = [[NSNetService alloc] initWithDomain:@"local." type:LANServiceType name:name port:port];
            owner->_service.delegate = owner;
            [owner->_service publish];
        });
    }
    return self;
}
- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict { self.failed = YES; }
- (void)stop {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self stop]; }); return; }
    _service.delegate = nil;
    [_service stop]; _service = nil;
}
- (void)dealloc {
    NSNetService *service = _service;
    service.delegate = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [service stop]; });
}
@end

@interface LANBrowser () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property (atomic, readwrite) BOOL discoveryFailed;
@end

@implementation LANServer
@end

@implementation LANBrowser {
    UDPTransport *_socket;
    NSMutableDictionary<NetAddress *, LANServer *> *_found;
    double _lastBroadcast;
    NSNetServiceBrowser *_browser;
    NSMutableArray<NSNetService *> *_services;
    NSMutableDictionary<NSString *, NetAddress *> *_resolved;
}

- (instancetype)init {
    if ((self = [super init])) {
        _socket = [[UDPTransport alloc] initWithPort:0 attempts:1];
        self.discoveryFailed = !_socket;
        _found = [NSMutableDictionary dictionary];
        _lastBroadcast = -100;
        _services = [NSMutableArray array];
        _resolved = [NSMutableDictionary dictionary];
        __weak LANBrowser *weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            LANBrowser *owner = weak;
            if (!owner) return;
            owner->_browser = [NSNetServiceBrowser new];
            owner->_browser.delegate = owner;
            [owner->_browser searchForServicesOfType:LANServiceType inDomain:@"local."];
        });
    }
    return self;
}

- (void)stop {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self stop]; }); return; }
    _browser.delegate = nil;
    [_browser stop]; _browser = nil;
    for (NSNetService *service in _services) { service.delegate = nil; [service stop]; }
    [_services removeAllObjects];
    @synchronized (self) { [_resolved removeAllObjects]; }
}

- (void)dealloc {
    NSNetServiceBrowser *browser = _browser;
    NSArray *services = [_services copy];
    browser.delegate = nil;
    for (NSNetService *service in services) service.delegate = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [browser stop];
        for (NSNetService *service in services) [service stop];
    });
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)more {
    [_services addObject:service];
    service.delegate = self;
    [service resolveWithTimeout:5];
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)more {
    @synchronized (self) { [_resolved removeObjectForKey:service.name]; }
    [_services removeObject:service];
    [service stop];
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary *)errorDict { self.discoveryFailed = YES; }
- (void)netServiceDidResolveAddress:(NSNetService *)service {
    for (NSData *data in service.addresses) {
        if (data.length < sizeof(struct sockaddr_in) || ((const struct sockaddr *)data.bytes)->sa_family != AF_INET) continue;
        NetAddress *address = [NetAddress addressWithSockaddr:data.bytes length:(unsigned)data.length];
        @synchronized (self) { _resolved[service.name] = address; }
        break;
    }
}

- (NSArray<LANServer *> *)servers {
    return [_found.allValues sortedArrayUsingComparator:^NSComparisonResult(LANServer *a, LANServer *b) {
        return [a.name compare:b.name];
    }];
}

- (void)query:(NetAddress *)address {
    if (address.sockaddr) [NetChannel sendOutOfBand:@"info" transport:_socket to:address];
}

- (void)poll {
    double now = CACurrentMediaTime();
    if (now - _lastBroadcast > 2.0) {
        _lastBroadcast = now;
        NSArray *resolved;
        @synchronized (self) { resolved = [_resolved.allValues copy]; }
        for (NetAddress *address in resolved) [self query:address];
#if !TARGET_OS_IOS
        MsgWriter *w = [MsgWriter new];
        [w u32:0xFFFFFFFF];
        [w bytes:[@"info" dataUsingEncoding:NSUTF8StringEncoding]];
        for (int i = 0; i < 4; i++) [_socket broadcast:w.data port:PORT_SERVER + i];
#endif
        // Forget servers that stopped answering.
        for (NetAddress *a in _found.allKeys) if (now - _found[a].lastSeen > 6) [_found removeObjectForKey:a];
    }
    NetAddress *from = nil;
    NSData *packet;
    while ((packet = [_socket receiveFrom:&from])) {
        NSString *text = [NetChannel outOfBandText:packet];
        if (![text hasPrefix:@"info_response "]) continue;
        // info_response <players> <max> <level or -> <name...>
        NSArray *f = [text componentsSeparatedByString:@" "];
        if (f.count < 5) continue;
        LANServer *s = _found[from] ?: [LANServer new];
        s.address = from;
        s.players = [f[1] intValue];
        s.maxPlayers = [f[2] intValue];
        s.levelName = [f[3] isEqualToString:@"-"] ? nil : f[3];
        s.name = [[f subarrayWithRange:NSMakeRange(4, f.count - 4)] componentsJoinedByString:@" "];
        s.lastSeen = now;
        _found[from] = s;
    }
}

@end
