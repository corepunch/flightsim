#import "MissionWorld.h"

typedef NS_ENUM(NSInteger, MissionObjectiveState) {
    MissionObjectiveHidden,     // waiting for its "after" objectives or for its targets to arrive
    MissionObjectiveActive,
    MissionObjectiveComplete,
    MissionObjectiveFailed,
};

@class MissionObjective;

// What an objective sees of the running mission.
@protocol MissionContext <NSObject>
@property (nonatomic, readonly) id<MissionWorld> world;
@property (nonatomic, readonly) double time;                 // mission seconds
- (NSArray<id<MissionUnit>> *)unitsNamed:(NSArray<NSString *> *)names;
- (NSArray<id<MissionUnit>> *)livePlayersNear:(simd_float3)point range:(float)range;
- (simd_float3)navPosition:(NSString *)nav;
- (void)objective:(MissionObjective *)o becomes:(MissionObjectiveState)state;
// The first active objective that wants the HUD's nav marker gets it.
- (void)pointAtNav:(NSString *)nav;
@end

// One objective of a level. The level entry:
//   { "id": "protect", "type": "protect", "targets": ["relay"], "text": "Keep bombers off Relay K-7",
//     "after": ["intercept"], "optional": false, … type-specific fields … }
// "targets" name units (entity ids, groups, waves); "navs" name navs. An
// objective stays hidden until every "after" objective is complete and every
// target has spawned.
//
// Types are classes registered by name. The engine registers every built-in
// type; a game may register a type only it can use (and move it here when a
// second game needs it).
@interface MissionObjective : NSObject

+ (void)registerType:(NSString *)type class:(Class)cls;
+ (Class)classForType:(NSString *)type;
+ (NSArray<NSString *> *)registeredTypes;
// Problems with a level entry of this type (missing or malformed fields).
+ (NSArray<NSString *> *)problemsWithDefinition:(NSDictionary *)definition;
// Ongoing objectives (protect) hold for the whole mission: they never block
// success and are marked complete when the mission succeeds.
+ (BOOL)ongoing;

+ (instancetype)objectiveWithDefinition:(NSDictionary *)definition;

@property (nonatomic, readonly) NSDictionary *definition;
@property (nonatomic, readonly) NSString *identifier, *type, *text;
@property (nonatomic, readonly) NSArray<NSString *> *targets, *navs, *after;
@property (nonatomic, readonly) BOOL optional;
@property (nonatomic) MissionObjectiveState state;
@property (nonatomic) double activatedAt;
@property (nonatomic, copy) NSString *progress;     // short text after the objective, may hold tokens

// Called every frame while active.
- (void)updateIn:(id<MissionContext>)context dt:(float)dt;

// Helpers for subclasses.
- (float)number:(NSString *)key fallback:(float)fallback;

@end
