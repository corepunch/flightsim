#import "ServerBrowser.h"
#import "Assets.h"
#import "UIStyle.h"

static NSColor *Ink(CGFloat a) { return UIColorWithOpacity(UIInk, a); }
static NSColor *Amber(CGFloat a) { return UIColorWithOpacity(UIAmber, a); }

static SKLabelNode *Text(CGFloat size, NSColor *c) {
    return UIMonoLabel(size, c, SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
}

@implementation ServerBrowser {
    SKNode *_root;
    NSArray<LANServer *> *_servers;
    NSUInteger _index;
    NSString *_status;
    NSString *_signature;
    CGSize _laidOut;
    CGRect _backRect, _joinRect, _serverRows;
    NSUInteger _firstVisible;
    CGPoint _pendingPoint;
    BOOL _hasPendingPoint;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = [NSColor clearColor];
        _root = [SKNode node];
        [self addChild:_root];
        _servers = @[];
    }
    return self;
}

- (LANServer *)selected { return _index < _servers.count ? _servers[_index] : nil; }

- (void)setStatus:(NSString *)status {
    _status = [status copy];
    _signature = nil;
    [self rebuild];
}

- (void)queueClickAtFraction:(CGPoint)point {
    @synchronized (self) {
        _pendingPoint = point;
        _hasPendingPoint = YES;
    }
}

- (void)showServers:(NSArray<LANServer *> *)servers {
    NSMutableString *sig = [NSMutableString string];
    for (LANServer *s in servers) [sig appendFormat:@"%@|%@|%d|%d;", s.address, s.name, s.players, s.missionIndex];
    if ([sig isEqualToString:_signature ?: @""] && CGSizeEqualToSize(_laidOut, self.size) && _signature) return;
    _signature = sig;
    LANServer *was = self.selected;
    _servers = servers;
    _index = 0;
    for (NSUInteger i = 0; i < servers.count; i++) if ([servers[i].address isEqual:was.address]) _index = i;
    [self rebuild];
}

- (void)rebuild {
    [_root removeAllChildren];
    _laidOut = self.size;
    CGSize s = self.size;
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:[NSColor colorWithWhite:0 alpha:0.72] size:s];
    shade.anchorPoint = CGPointZero;
    [_root addChild:shade];

    CGFloat x = MIN(110, s.width * 0.08), y = s.height - MIN(90, s.height * 0.14);
    SKLabelNode *kicker = Text(14, Ink(0.6));
    kicker.text = @"KESTREL FRONTIER  /  MULTIPLAYER";
    kicker.position = CGPointMake(x, y);
    [_root addChild:kicker];
    SKLabelNode *title = Text(34, Ink(1));
    title.text = @"Games on this network";
    title.position = CGPointMake(x, y - 26);
    [_root addChild:title];

    y -= 84;
    if (!_servers.count) {
        SKLabelNode *none = Text(17, Ink(0.55));
        none.text = @"Searching for games on this network…";
        none.position = CGPointMake(x, y);
        [_root addChild:none];
    }
    CGFloat rowHeight = 36, width = s.width - 2 * x;
    NSUInteger visible = MIN(_servers.count, (NSUInteger)MAX(1, floor((y - 143) / rowHeight)));
    _firstVisible = visible && _index >= visible ? _index - visible + 1 : 0;
    _serverRows = CGRectMake(x, y - visible * rowHeight, width, visible * rowHeight);
    for (NSUInteger i = _firstVisible; i < _firstVisible + visible; i++) {
        LANServer *srv = _servers[i];
        BOOL sel = i == _index;
        NSString *mission = srv.missionIndex >= 0 ? CampaignMission((NSUInteger)srv.missionIndex)[@"title"] : nil;
        SKLabelNode *l = Text(16, sel ? Amber(1) : Ink(0.85));
        l.text = [NSString stringWithFormat:@"%@ %@   %d/%d pilots   %@   %@", sel ? @">" : @" ", srv.name, srv.players, srv.maxPlayers,
                  mission ? [NSString stringWithFormat:@"flying \"%@\"", mission] : @"in the menus", srv.address];
        l.numberOfLines = 1;
        l.preferredMaxLayoutWidth = width;
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        l.position = CGPointMake(x, y - (i - _firstVisible) * rowHeight);
        [_root addChild:l];
    }

    NSArray *lines = @[
        _status ?: @"",
        _hostLine ?: @"",
        s.width >= 850 ? @"Direct IP: SpaceFight --connect <host[:port]>   /   Dedicated: SpaceFight --dedicated [mission]" : @"↑ / ↓  Select   •   Return  Join   •   Esc  Back",
    ];
    for (NSUInteger i = 0; i < lines.count; i++) {
        SKLabelNode *l = Text(i == 0 ? 14 : 12, i == 0 ? Amber(1) : Ink(0.55));
        l.text = lines[i];
        l.numberOfLines = 1;
        l.preferredMaxLayoutWidth = width;
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        l.position = CGPointMake(x, 130 - i * 20);
        [_root addChild:l];
    }
    _backRect = CGRectMake(x, 20, 145, 44);
    _joinRect = self.selected ? CGRectMake(s.width - x - 145, 20, 145, 44) : CGRectZero;
    [_root addChild:UIActionButton(_backRect, @"‹  BACK", UIInk)];
    if (self.selected) [_root addChild:UIActionButton(_joinRect, @"JOIN GAME  ›", UIAmber)];
}

- (void)update:(NSTimeInterval)currentTime {
    if (!CGSizeEqualToSize(_laidOut, self.size)) [self rebuild];
}

- (BrowserCommand)handle:(InputAction)actions {
    CGPoint click = CGPointMake(-1, -1);
    @synchronized (self) {
        if (_hasPendingPoint) click = CGPointMake(_pendingPoint.x * self.size.width, _pendingPoint.y * self.size.height);
        _hasPendingPoint = NO;
    }
    if (CGRectContainsPoint(_backRect, click)) actions |= InputActionBack;
    else if (CGRectContainsPoint(_joinRect, click)) actions |= InputActionConfirm;
    else if (CGRectContainsPoint(_serverRows, click)) {
        NSUInteger row = _firstVisible + (NSUInteger)((CGRectGetMaxY(_serverRows) - click.y) / 36);
        if (row < _servers.count) { _index = row; [self rebuild]; }
    }
    if (actions & InputActionBack) return BrowserCommandBack;
    if (_servers.count) {
        if (actions & InputActionUp) { _index = (_index + _servers.count - 1) % _servers.count; [self rebuild]; }
        if (actions & InputActionDown) { _index = (_index + 1) % _servers.count; [self rebuild]; }
        if (actions & InputActionConfirm) return BrowserCommandJoin;
    }
    return BrowserCommandNone;
}

@end
