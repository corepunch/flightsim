#import "Net.h"
#import <QuartzCore/QuartzCore.h>
#include <netinet/in.h>
#include <dns_sd.h>

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
            NSLog(@"LAN: publishing %@ on UDP %d", name, port);
            [owner->_service publish];
        });
    }
    return self;
}
- (void)netServiceDidPublish:(NSNetService *)sender { NSLog(@"LAN: published %@", sender.name); }
- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict {
    NSLog(@"LAN: publication failed: %@", errorDict); self.failed = YES;
}
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
@property (atomic) BOOL stopped;
@property (atomic, readwrite) BOOL socketFailed;
@property (atomic, readwrite, strong) NSError *searchError;
@property (atomic, readwrite, strong) NSError *resolutionError;
@property (atomic, readwrite) BOOL hostUnreachable;
@end

@implementation LANServer
@end

@implementation LANBrowser {
    UDPTransport *_socket;
    NSMutableDictionary<NetAddress *, LANServer *> *_found;
    double _lastBroadcast, _firstResolved;
    NSNetServiceBrowser *_browser;
    NSMutableArray<NSNetService *> *_services;
    NSMutableDictionary<NSString *, NSArray<NetAddress *> *> *_resolved;
    NSMutableDictionary<NetAddress *, NSString *> *_instances;
}

- (instancetype)init {
    return [self initWithSocket:[[UDPTransport alloc] initWithPort:0 attempts:1]];
}

- (instancetype)initWithSocket:(UDPTransport *)socket {
    if ((self = [super init])) {
        _socket = socket;
        self.socketFailed = !_socket;
        _found = [NSMutableDictionary dictionary];
        _lastBroadcast = -100;
        _services = [NSMutableArray array];
        _resolved = [NSMutableDictionary dictionary];
        _instances = [NSMutableDictionary dictionary];
        __weak LANBrowser *weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            LANBrowser *owner = weak;
            if (!owner || owner.stopped) return;
            owner->_browser = [NSNetServiceBrowser new];
            owner->_browser.delegate = owner;
            [owner->_browser searchForServicesOfType:LANServiceType inDomain:@"local."];
        });
    }
    return self;
}

- (void)stop {
    self.stopped = YES;
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self stop]; }); return; }
    _browser.delegate = nil;
    [_browser stop]; _browser = nil;
    for (NSNetService *service in _services) { service.delegate = nil; [service stop]; }
    [_services removeAllObjects];
    @synchronized (self) { [_resolved removeAllObjects]; [_instances removeAllObjects]; }
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
    NSLog(@"LAN: discovered %@", service.name);
    [_services addObject:service];
    service.delegate = self;
    [service resolveWithTimeout:5];
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)more {
    @synchronized (self) { [_resolved removeObjectForKey:service.name]; }
    [_services removeObject:service];
    [service stop];
}
- (BOOL)accessDenied {
    return self.searchError.code == kDNSServiceErr_PolicyDenied || self.resolutionError.code == kDNSServiceErr_PolicyDenied;
}

- (BOOL)discoveryFailed { return self.socketFailed || self.searchError != nil; }

- (NSError *)bonjourError:(NSDictionary *)details service:(NSString *)name {
    NSError *error = [NSError errorWithDomain:[NSString stringWithFormat:@"Bonjour/%@", details[NSNetServicesErrorDomain] ?: @"unknown"]
        code:[details[NSNetServicesErrorCode] integerValue] userInfo:nil];
    NSLog(@"LAN: %@: %@", name, error);
    return error;
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary *)errorDict {
    self.searchError = [self bonjourError:errorDict service:@"search _kestrel._udp"];
}
- (void)netServiceBrowserWillSearch:(NSNetServiceBrowser *)browser { self.searchError = nil; }
- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary *)errorDict {
    self.resolutionError = [self bonjourError:errorDict service:service.name];
}
- (void)netServiceDidResolveAddress:(NSNetService *)service {
    self.resolutionError = nil;
    NSMutableArray<NetAddress *> *addresses = [NSMutableArray array];
    for (NSData *data in service.addresses) {
        if (data.length < sizeof(struct sockaddr_in) || ((const struct sockaddr *)data.bytes)->sa_family != AF_INET) continue;
        NetAddress *address = [NetAddress addressWithSockaddr:data.bytes length:(unsigned)data.length];
        if (![addresses containsObject:address]) [addresses addObject:address];
    }
    if (!addresses.count) {
        self.resolutionError = [NSError errorWithDomain:@"LANAddress" code:1 userInfo:nil];
        NSLog(@"LAN: %@ resolved without a usable IPv4 address", service.name);
        return;
    }
    NSLog(@"LAN: resolved %@: %@", service.name, addresses);
    @synchronized (self) {
        if (!_resolved.count) _firstResolved = CACurrentMediaTime();
        _resolved[service.name] = addresses;
        for (NetAddress *address in addresses) _instances[address] = service.name;
    }
}

- (NSArray<LANServer *> *)servers {
    NSArray *servers = [_found.allValues filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LANServer *server, NSDictionary *bindings) { return server.name.length > 0; }]];
    return [servers sortedArrayUsingComparator:^NSComparisonResult(LANServer *a, LANServer *b) {
        return [a.name compare:b.name];
    }];
}

- (void)query:(NetAddress *)address {
    if (address.sockaddr) {
        [NetChannel sendOutOfBand:@"info" transport:_socket to:address];
        [NetChannel sendOutOfBand:@"lobby" transport:_socket to:address];
    }
}

- (void)poll {
    double now = CACurrentMediaTime();
    if (now - _lastBroadcast > 2.0) {
        _lastBroadcast = now;
        NSArray *resolved;
        @synchronized (self) { resolved = [_resolved.allValues copy]; }
        for (NSArray<NetAddress *> *addresses in resolved) for (NetAddress *address in addresses) [self query:address];
#if !TARGET_OS_IOS
        MsgWriter *w = [MsgWriter new];
        [w u32:0xFFFFFFFF];
        [w bytes:[@"info" dataUsingEncoding:NSUTF8StringEncoding]];
        for (int i = 0; i < 4; i++) [_socket broadcast:w.data port:PORT_SERVER + i];
#endif
        // Forget servers that stopped answering.
        for (NetAddress *a in _found.allKeys) if (now - _found[a].lastSeen > 6) [_found removeObjectForKey:a];
    }
    @synchronized (self) {
        self.hostUnreachable = _resolved.count && !_found.count && now - _firstResolved > 6;
    }
    NetAddress *from = nil;
    NSData *packet;
    while ((packet = [_socket receiveFrom:&from])) {
        NSString *text = [NetChannel outOfBandText:packet];
        // Several interfaces can answer for one service. Keep its first live
        // route stable, and try alternatives after that route stops replying.
        NSString *instance;
        NSDictionary *instances;
        @synchronized (self) { instance=_instances[from]; instances=[_instances copy]; }
        BOOL duplicate=NO;
        if (instance) for (NetAddress *address in _found)
            if (![address isEqual:from] && [instances[address] isEqualToString:instance] && now-_found[address].lastSeen<6) { duplicate=YES; break; }
        if (duplicate) continue;
        if ([text hasPrefix:@"lobby_response "]) {
            LANLobbyInfo lobby;
            if (LANLobbyDecode([text substringFromIndex:@"lobby_response ".length], &lobby)) {
                LANServer *server = _found[from] ?: [LANServer new];
                server.address = from; server.settings = lobby.settings; server.pilots = lobby.pilots;
                server.lastSeen = now; _found[from] = server;
            }
            continue;
        }
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
        if (!s.pilots) s.settings = LANMatchSettingsDefault();
        s.lastSeen = now;
        _found[from] = s;
        self.hostUnreachable = NO;
    }
}

@end
