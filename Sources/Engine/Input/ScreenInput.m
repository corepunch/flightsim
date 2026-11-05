#import "Input.h"

// More than a frame's worth of input; older events are dropped past this.
static const NSUInteger kMaxQueued = 256;

@implementation PointerQueue {
    NSMutableData *_events;
}

- (instancetype)init {
    if ((self = [super init])) _events = [NSMutableData data];
    return self;
}

- (void)push:(PointerEvent)event {
    @synchronized (self) {
        // Successive hovers collapse into the latest one.
        NSUInteger n = _events.length / sizeof(PointerEvent);
        PointerEvent *last = n ? (PointerEvent *)_events.mutableBytes + n - 1 : NULL;
        if (last && last->kind == PointerEventHover && event.kind == PointerEventHover) { *last = event; return; }
        if (n >= kMaxQueued) [_events replaceBytesInRange:NSMakeRange(0, sizeof(PointerEvent)) withBytes:NULL length:0];
        [_events appendBytes:&event length:sizeof event];
    }
}

- (NSData *)drain {
    @synchronized (self) {
        NSData *all = [_events copy];
        _events.length = 0;
        return all;
    }
}

@end
