#import "UI.h"
#import "Audio.h"

@implementation ScreenHost {
    void (^_install)(SKScene *, SKNode *);
    SKNode *_cover;
    double _deadline;
    void (^_then)(void);
}

- (instancetype)initWithScreen:(SKScene *)first install:(void (^)(SKScene *, SKNode *))install {
    if ((self = [super init])) {
        _shown = first;
        _install = [install copy];
    }
    return self;
}

- (BOOL)changing { return _deadline > 0; }

- (void)present:(SKScene *)next cover:(SKNode *)cover time:(double)now {
    if (next == _shown && _deadline == 0) return;
    if (cover && _shown && _shown != next && !_cover) {
        _cover = cover;
        _cover.zPosition = -1;
        [_shown addChild:_cover];
    }
    __weak ScreenHost *weak = self;
    void (^show)(void) = ^{ [weak installNow:next]; };
    if (_deadline > 0) { _then = show; return; }
    NSTimeInterval exit = [_shown conformsToProtocol:@protocol(UIMotionScene)] ? [(id<UIMotionScene>)_shown motionExit] : 0;
    [self after:exit then:show time:now];
}

- (void)after:(NSTimeInterval)seconds then:(void (^)(void))then time:(double)now {
    if (seconds <= 0) { _deadline = 0; _then = nil; then(); return; }
    _then = then;
    _deadline = now + seconds * UIMotionTimeScale() + 0.02;
}

- (void)installNow:(SKScene *)next {
    _shown = next;
    SKNode *cover = _cover;
    _cover = nil;
    if ([next conformsToProtocol:@protocol(UIMotionScene)]) [(id<UIMotionScene>)next motionEnter];
    _install(next, cover);
}

- (void)pump:(double)now {
    if (_deadline <= 0 || now < _deadline) return;
    void (^then)(void) = _then;
    _deadline = 0;
    _then = nil;
    if (then) then();
}

@end
