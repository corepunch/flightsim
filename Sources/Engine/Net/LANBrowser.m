#import "LANBrowser.h"
#import "UDPTransport.h"
#import "NetChannel.h"
#import "NetProtocol.h"
#import "NetMsg.h"
#import <QuartzCore/QuartzCore.h>

@implementation LANServer
@end

@implementation LANBrowser {
    UDPTransport *_socket;
    NSMutableDictionary<NetAddress *, LANServer *> *_found;
    double _lastBroadcast;
}

- (instancetype)init {
    if ((self = [super init])) {
        _socket = [[UDPTransport alloc] initWithPort:0 attempts:1];
        _found = [NSMutableDictionary dictionary];
        _lastBroadcast = -100;
    }
    return self;
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
        MsgWriter *w = [MsgWriter new];
        [w u32:0xFFFFFFFF];
        [w bytes:[@"info" dataUsingEncoding:NSUTF8StringEncoding]];
        for (int i = 0; i < 4; i++) [_socket broadcast:w.data port:PORT_SERVER + i];
        // Forget servers that stopped answering.
        for (NetAddress *a in _found.allKeys) if (now - _found[a].lastSeen > 6) [_found removeObjectForKey:a];
    }
    NetAddress *from = nil;
    NSData *packet;
    while ((packet = [_socket receiveFrom:&from])) {
        NSString *text = [NetChannel outOfBandText:packet];
        if (![text hasPrefix:@"info_response "]) continue;
        // info_response <players> <max> <mission or -> <name...>
        NSArray *f = [text componentsSeparatedByString:@" "];
        if (f.count < 5) continue;
        LANServer *s = _found[from] ?: [LANServer new];
        s.address = from;
        s.players = [f[1] intValue];
        s.maxPlayers = [f[2] intValue];
        s.missionIndex = [f[3] isEqualToString:@"-"] ? -1 : [f[3] intValue];
        s.name = [[f subarrayWithRange:NSMakeRange(4, f.count - 4)] componentsJoinedByString:@" "];
        s.lastSeen = now;
        _found[from] = s;
    }
}

@end
