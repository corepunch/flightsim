#import "Common.h"

@implementation ObjectiveReadout
- (instancetype)initWithText:(NSString *)text status:(ObjectiveStatus)status {
    if ((self = [super init])) {
        _text = [text copy];
        _status = status;
    }
    return self;
}
@end

NSArray<ObjectiveReadout *> *FlightObjectiveReadouts(NSString *text, NSString *states) {
    if (!text.length) return @[];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray<ObjectiveReadout *> *items = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSUInteger i = 0; i < lines.count; i++) {
        unichar code = i < states.length ? [states characterAtIndex:i] : '0';
        ObjectiveStatus status = code == '1' ? ObjectiveComplete : code == '2' ? ObjectiveFailed : ObjectiveOpen;
        [items addObject:[[ObjectiveReadout alloc] initWithText:L10nExpand(lines[i]) status:status]];
    }
    return items;
}

NSArray<ObjectiveReadout *> *MissionResultReadouts(NSArray<NSString *> *lines) {
    NSMutableArray<ObjectiveReadout *> *items = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSString *line in lines) {
        ObjectiveStatus status = ObjectiveOpen;
        NSString *text = line;
        if ([line hasPrefix:@"+ "]) status = ObjectiveComplete;
        else if ([line hasPrefix:@"x "]) status = ObjectiveFailed;
        if (status != ObjectiveOpen || [line hasPrefix:@"- "]) text = [line substringFromIndex:2];
        [items addObject:[[ObjectiveReadout alloc] initWithText:L10nExpand(text) status:status]];
    }
    return items;
}
