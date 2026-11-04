#import "UDPTransport.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

@implementation UDPTransport {
    int _fd;
}

- (instancetype)initWithPort:(int)port attempts:(int)attempts {
    if ((self = [super init])) {
        _fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (_fd < 0) { NSLog(@"UDP: socket: %s", strerror(errno)); return nil; }
        int one = 1;
        setsockopt(_fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof one);
        int size = 1 << 20;   // a burst of fragments shouldn't overflow the buffer
        setsockopt(_fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof size);
        fcntl(_fd, F_SETFL, fcntl(_fd, F_GETFL) | O_NONBLOCK);
        BOOL bound = NO;
        for (int i = 0; i < MAX(attempts, 1) && !bound; i++) {
            struct sockaddr_in sin = { .sin_len = sizeof sin, .sin_family = AF_INET,
                                       .sin_port = htons((uint16_t)(port ? port + i : 0)), .sin_addr.s_addr = INADDR_ANY };
            bound = bind(_fd, (struct sockaddr *)&sin, sizeof sin) == 0;
        }
        if (!bound) {
            NSLog(@"UDP: cannot bind port %d: %s", port, strerror(errno));
            close(_fd);
            return nil;
        }
        struct sockaddr_in actual;
        socklen_t len = sizeof actual;
        getsockname(_fd, (struct sockaddr *)&actual, &len);
        _port = ntohs(actual.sin_port);
        NSLog(@"UDP: listening on port %d", _port);
    }
    return self;
}

- (void)dealloc {
    if (_fd >= 0) close(_fd);
}

- (void)send:(NSData *)packet to:(NetAddress *)to {
    NSData *sa = to.sockaddr;
    if (!sa) return;
    sendto(_fd, packet.bytes, packet.length, 0, sa.bytes, (socklen_t)sa.length);
}

- (void)broadcast:(NSData *)packet port:(int)port {
    struct sockaddr_in sin = { .sin_len = sizeof sin, .sin_family = AF_INET,
                               .sin_port = htons((uint16_t)port), .sin_addr.s_addr = INADDR_BROADCAST };
    sendto(_fd, packet.bytes, packet.length, 0, (struct sockaddr *)&sin, sizeof sin);
}

- (NSData *)receiveFrom:(NetAddress *__autoreleasing *)from {
    uint8_t buf[65536];
    struct sockaddr_in sin;
    socklen_t len = sizeof sin;
    ssize_t n = recvfrom(_fd, buf, sizeof buf, 0, (struct sockaddr *)&sin, &len);
    if (n < 0) return nil;
    *from = [NetAddress addressWithSockaddr:&sin length:len];
    return [NSData dataWithBytes:buf length:(NSUInteger)n];
}

@end
