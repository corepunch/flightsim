#import "Mission.h"

@implementation Objective
- (NSString *)identifier { return _def[@"id"]; }
- (NSString *)type { return _def[@"type"]; }
- (NSString *)text { return _def[@"text"]; }
- (NSArray<NSString *> *)targets { return _def[@"targets"] ?: @[]; }
- (NSArray<NSString *> *)navs { return _def[@"navs"] ?: @[]; }
- (NSArray<NSString *> *)after { return _def[@"after"] ?: @[]; }
- (BOOL)optional { return [_def[@"optional"] boolValue]; }
@end

static NSString *const kUnlockedKey = @"SFMissionsUnlocked";

@implementation Mission

+ (NSArray<NSDictionary *> *)all {
    static NSArray *missions;
    if (!missions) {
        NSURL *url = [[NSBundle mainBundle] URLForResource:@"missions" withExtension:@"json" subdirectory:@"Missions"];
        NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
        NSError *err = nil;
        NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&err] : nil;
        if (!root) NSLog(@"Mission: cannot load missions.json: %@", err);
        missions = root[@"missions"] ?: @[];
    }
    return missions;
}

+ (NSDictionary *)missionAtIndex:(NSUInteger)i {
    NSArray *all = [self all];
    return i < all.count ? all[i] : nil;
}

+ (NSUInteger)unlockedCount {
    if (getenv("SF_UNLOCK_ALL")) return [self all].count;
    NSInteger n = [[NSUserDefaults standardUserDefaults] integerForKey:kUnlockedKey];
    return MAX(1, MIN((NSUInteger)n, [self all].count));
}

+ (void)markCompleted:(NSUInteger)index {
    NSUInteger next = MIN(index + 2, [self all].count);
    if (next > [self unlockedCount]) [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)next forKey:kUnlockedKey];
}

+ (NSArray<Objective *> *)objectivesFor:(NSDictionary *)mission {
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *d in mission[@"objectives"]) {
        Objective *o = [Objective new];
        o.def = d;
        o.state = ObjectiveHidden;
        o.scanTime = [NSMutableDictionary dictionary];
        o.progress = @"";
        [list addObject:o];
    }
    return list;
}

@end
