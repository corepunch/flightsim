#import "Story.h"
#import "Common.h"
#include <stdatomic.h>

static const NSUInteger ProgressFormat = 1;
static const NSUInteger StarsPerMission = 3;
static const NSUInteger PointsPerStar = 100;
NSNotificationName const ProgressDidChange = @"ProgressDidChange";

static NSUInteger SaveInteger(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSNumber.class]) return 0;
    double n = [value doubleValue];
    return n >= 0 && n <= limit && n == trunc(n) ? (NSUInteger)n : 0;
}

static NSDictionary<NSString *, NSNumber *> *SaveRecords(NSDictionary *raw, NSUInteger limit) {
    NSMutableDictionary *records = [NSMutableDictionary dictionary];
    for (id key in raw) {
        if (![key isKindOfClass:NSString.class] || ![key length]) continue;
        NSUInteger value = SaveInteger(raw[key], limit);
        if (value) records[key] = @(value);
    }
    return [records copy];
}

static NSDictionary<NSString *, NSNumber *> *BestRecords(NSDictionary *a, NSDictionary *b) {
    NSMutableDictionary *best = [a mutableCopy];
    for (NSString *key in b)
        if ([b[key] unsignedIntegerValue] > [best[key] unsignedIntegerValue]) best[key] = b[key];
    return best;
}

@implementation ProgressSave

- (instancetype)initStarted:(BOOL)started unlocked:(NSUInteger)unlocked completed:(NSUInteger)completed
                      stars:(NSDictionary *)stars arenas:(NSDictionary *)arenas {
    if ((self = [super init])) {
        _started = started;
        _unlocked = unlocked;
        _completed = completed;
        _missionStars = [stars copy];
        _arenaScores = [arenas copy];
    }
    return self;
}

+ (instancetype)empty {
    return [[self alloc] initStarted:NO unlocked:1 completed:0 stars:@{} arenas:@{}];
}

+ (instancetype)fromData:(NSData *)data {
    if (!data.length || data.length > 1024 * 1024) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    NSUInteger format = SaveInteger(JSONNumber(plist, @"version"), UINT32_MAX);
    NSDictionary *stars = JSONObject(plist, @"missionStars"), *arenas = JSONObject(plist, @"arenaScores");
    NSUInteger unlocked = SaveInteger(JSONNumber(plist, @"unlocked"), UINT32_MAX);
    if (format != ProgressFormat || !stars || !arenas || !unlocked) return nil;
    return [[self alloc] initStarted:JSONBool(plist, @"started", NO)
                            unlocked:unlocked completed:SaveInteger(JSONNumber(plist, @"completed"), UINT32_MAX)
                               stars:SaveRecords(stars, StarsPerMission) arenas:SaveRecords(arenas, LANMatchMaxPilotPoints)];
}

- (NSData *)encodedData {
    NSDictionary *plist = @{@"version": @(ProgressFormat), @"started": @(_started),
        @"unlocked": @(_unlocked), @"completed": @(_completed), @"missionStars": _missionStars, @"arenaScores": _arenaScores};
    return [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}

- (ProgressSave *)merging:(ProgressSave *)other {
    return [[ProgressSave alloc] initStarted:_started || other.started
                                   unlocked:MAX(_unlocked, other.unlocked) completed:MAX(_completed, other.completed)
                                      stars:BestRecords(_missionStars, other.missionStars)
                                     arenas:BestRecords(_arenaScores, other.arenaScores)];
}

- (BOOL)isEqual:(id)object {
    if (object == self) return YES;
    if (![object isKindOfClass:ProgressSave.class]) return NO;
    ProgressSave *other = object;
    return _started == other.started && _unlocked == other.unlocked && _completed == other.completed &&
        [_missionStars isEqual:other.missionStars] && [_arenaScores isEqual:other.arenaScores];
}

- (NSUInteger)hash {
    return _started ^ _unlocked ^ _completed ^ _missionStars.hash ^ _arenaScores.hash;
}
@end

// The default game owns the original preference namespace. Other games use
// separate records even when they run in the same app.
static NSString *GameKey(NSString *key, NSString *game) {
    NSString *preferred = [NSBundle.mainBundle objectForInfoDictionaryKey:@"FSDefaultGame"];
    return !game.length || [game isEqualToString:preferred] ? key : [NSString stringWithFormat:@"%@.%@", game, key];
}

static ProgressSave *MigrateProgress(NSUserDefaults *defaults, NSString *game) {
    NSUInteger unlocked = MAX(1, [defaults integerForKey:GameKey(@"SFMissionsUnlocked", game)]);
    NSString *completedKey = GameKey(@"SFCampaignCompletedCount", game);
    NSUInteger completed = [defaults objectForKey:completedKey] ? MAX(0, [defaults integerForKey:completedKey]) :
        [defaults boolForKey:GameKey(@"SFCampaignCompleted", game)] ? unlocked : 0;
    NSString *legacyKey = GameKey(@"SFLegacyStarsCount", game);
    NSUInteger legacy = [defaults objectForKey:legacyKey] ? MAX(0, [defaults integerForKey:legacyKey]) : MAX(unlocked - 1, completed);
    NSDictionary *ratings = [defaults dictionaryForKey:GameKey(@"SFMissionStars", game)];
    NSMutableDictionary *stars = [NSMutableDictionary dictionary];
    NSArray<CampaignMission *> *missions = CampaignMissions();
    for (NSUInteger i = 0; i < missions.count; i++) {
        NSNumber *rating = ratings[[@(i) stringValue]];
        NSUInteger value = [rating isKindOfClass:NSNumber.class] ? SaveInteger(rating, StarsPerMission) : i < legacy;
        if (value) stars[missions[i].levelName] = @(value);
    }
    NSDictionary *arenas = [defaults dictionaryForKey:GameKey(@"SFArenaScores", game)];
    return [[ProgressSave alloc] initStarted:[defaults boolForKey:GameKey(@"SFCampaignStarted", game)]
                                    unlocked:unlocked completed:completed stars:stars
                                       arenas:SaveRecords(arenas, LANMatchMaxPilotPoints)];
}

static NSMutableDictionary<NSString *, ProgressSave *> *localSaves;
static _Atomic NSUInteger revision;

static ProgressSave *LoadProgress(NSString *game) {
    if (!localSaves) localSaves = [NSMutableDictionary dictionary];
    ProgressSave *save = localSaves[game];
    if (!save) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        save = [ProgressSave fromData:[defaults dataForKey:GameKey(@"SFPilotProgress", game)]];
        localSaves[game] = save = save ?: MigrateProgress(defaults, game);
    }
    return save;
}

NSUInteger ProgressRevision(void) { return atomic_load(&revision); }

ProgressSave *ProgressSnapshot(void) {
    NSString *game = FSGame();
    @synchronized (ProgressSave.class) { return LoadProgress(game); }
}

static ProgressSave *UpdateProgress(ProgressSave *(^change)(ProgressSave *)) {
    NSString *game = FSGame();
    ProgressSave *updated;
    @synchronized (ProgressSave.class) {
        ProgressSave *local = LoadProgress(game);
        updated = change(local);
        if ([updated isEqual:local]) return local;
        [NSUserDefaults.standardUserDefaults setObject:updated.encodedData forKey:GameKey(@"SFPilotProgress", game)];
        localSaves[game] = updated;
        atomic_fetch_add(&revision, 1);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:ProgressDidChange object:nil];
    return updated;
}

ProgressSave *ProgressMerge(ProgressSave *cloud) {
    return UpdateProgress(^ProgressSave *(ProgressSave *local) { return [local merging:cloud]; });
}

NSUInteger ProgressUnlockedCount(void) {
    NSUInteger total = CampaignMissions().count;
    static Cvar *unlockAll;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unlockAll = [Cvar get:@"ui_unlockAll" defaultValue:@"0" flags:CVAR_CHEAT help:@"Every mission is open"];
    });
    if (unlockAll.boolValue) return total;
    ProgressSave *save = ProgressSnapshot();
    return MAX(1, MIN(MAX(save.unlocked, save.completed + 1), total));
}

BOOL ProgressHasStarted(void) {
    ProgressSave *save = ProgressSnapshot();
    return save.started || save.unlocked > 1;
}

BOOL ProgressCampaignCompleted(void) {
    NSUInteger count = CampaignMissions().count;
    return count && ProgressSnapshot().completed >= count;
}

void ProgressMarkStarted(void) {
    UpdateProgress(^ProgressSave *(ProgressSave *local) {
        if (local.started) return local;
        return [[ProgressSave alloc] initStarted:YES unlocked:local.unlocked completed:local.completed
                                           stars:local.missionStars arenas:local.arenaScores];
    });
}

NSUInteger ProgressBestStars(NSUInteger index) {
    NSString *level = CampaignLevelName(index);
    return level ? ProgressSnapshot().missionStars[level].unsignedIntegerValue : 0;
}

NSUInteger ProgressResultStars(NSArray<ObjectiveReadout *> *results) {
    NSUInteger done = 0;
    for (ObjectiveReadout *item in results) if (item.status == ObjectiveComplete) done++;
    return results.count == 0 ? 1 : done == results.count ? 3 : done * 4 >= results.count * 3 ? 2 : 1;
}

NSUInteger ProgressRecordResult(NSUInteger index, NSUInteger stars) {
    NSString *level = CampaignLevelName(index);
    if (!level || !stars) return 0;
    NSUInteger count = CampaignMissions().count;
    stars = MIN(StarsPerMission, stars);
    __block NSUInteger points = 0;
    UpdateProgress(^ProgressSave *(ProgressSave *local) {
        NSUInteger best = MAX(stars, local.missionStars[level].unsignedIntegerValue);
        points = (best - local.missionStars[level].unsignedIntegerValue) * PointsPerStar;
        NSMutableDictionary *ratings = [local.missionStars mutableCopy];
        ratings[level] = @(best);
        return [[ProgressSave alloc] initStarted:YES unlocked:MAX(local.unlocked, MIN(index + 2, count))
                                       completed:MAX(local.completed, index + 1 == count ? count : 0)
                                           stars:ratings arenas:local.arenaScores];
    });
    return points;
}

NSUInteger ProgressRecordMatch(NSString *arena, LANMatchResult result) {
    const LevelDef *level = arena.length ? LevelNamed(arena) : NULL;
    if (!level || !level->rules.deathmatch) return 0;
    NSUInteger points = LANMatchPilotPoints(result);
    __block NSUInteger increase = 0;
    UpdateProgress(^ProgressSave *(ProgressSave *local) {
        NSUInteger previous = local.arenaScores[arena].unsignedIntegerValue;
        if (points <= previous) return local;
        increase = points - previous;
        NSMutableDictionary *best = [local.arenaScores mutableCopy];
        best[arena] = @(points);
        return [[ProgressSave alloc] initStarted:local.started unlocked:local.unlocked completed:local.completed
                                           stars:local.missionStars arenas:best];
    });
    return increase;
}

@implementation AchievementProgress
- (instancetype)initWithIdentifier:(NSString *)identifier percent:(double)percent {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _percent = percent;
    }
    return self;
}
@end

NSArray<AchievementProgress *> *ProgressAchievements(ProgressSave *save) {
    NSUInteger finished = 0, perfect = 0, matchPoints = 0;
    for (CampaignMission *mission in CampaignMissions()) {
        NSUInteger stars = save.missionStars[mission.levelName].unsignedIntegerValue;
        finished += stars > 0;
        perfect += stars >= StarsPerMission;
    }
    for (NSNumber *points in save.arenaScores.allValues) matchPoints = MAX(matchPoints, points.unsignedIntegerValue);
    const NSUInteger reached[] = { [AchievementMissions] = finished, [AchievementPerfect] = perfect,
                                   [AchievementMatchPoints] = matchPoints };
    NSMutableArray<AchievementProgress *> *list = [NSMutableArray array];
    for (CampaignAchievement *achievement in CampaignAchievements()) {
        double percent = MIN(100.0, reached[achievement.rule] * 100.0 / achievement.count);
        [list addObject:[[AchievementProgress alloc] initWithIdentifier:achievement.identifier percent:percent]];
    }
    return list;
}

uint64_t CampaignLevelTag(NSString *level) {
    if (!level.length) return 0;
    // FNV-1a over the name's UTF-8 bytes; the value has to be the same on every device and build.
    uint64_t hash = 14695981039346656037ull;
    for (const unsigned char *byte = (const unsigned char *)level.UTF8String; *byte; byte++)
        hash = (hash ^ *byte) * 1099511628211ull;
    return hash ?: 1;
}

uint64_t ProgressCampaignTag(void) {
    ProgressSave *save = ProgressSnapshot();
    NSUInteger count = CampaignMissions().count;
    if (!count || save.completed >= count) return 0;
    return CampaignLevelTag(CampaignLevelName(MIN(MAX(save.unlocked, (NSUInteger)1), count) - 1));
}

NSUInteger CampaignIndexOfTag(uint64_t tag) {
    NSUInteger count = tag ? CampaignMissions().count : 0;
    for (NSUInteger i = 0; i < count; i++)
        if (CampaignLevelTag(CampaignLevelName(i)) == tag) return i;
    return NSNotFound;
}

NSUInteger ProgressPilotScore(void) {
    ProgressSave *save = ProgressSnapshot();
    NSUInteger total = 0;
    for (NSNumber *value in save.missionStars.allValues) total += value.unsignedIntegerValue * PointsPerStar;
    for (NSNumber *value in save.arenaScores.allValues) total += value.unsignedIntegerValue;
    return total;
}
