#import <Foundation/Foundation.h>
#import <simd/simd.h>

typedef NS_ENUM(NSInteger, ObjectiveState) {
    ObjectiveHidden,     // waiting for its "after" objectives or for its targets to arrive
    ObjectiveActive,
    ObjectiveComplete,
    ObjectiveFailed,
};

// One mission objective from Resources/Missions/missions.json, with its
// runtime state. Types: reach, destroy, protect, escort, survive, scan,
// collect, disable (see the JSON for the fields each uses).
@interface Objective : NSObject
@property (nonatomic, copy) NSDictionary *def;
@property (nonatomic, readonly) NSString *identifier, *type, *text;
@property (nonatomic, readonly) NSArray<NSString *> *targets, *navs, *after;
@property (nonatomic, readonly) BOOL optional;
@property (nonatomic) ObjectiveState state;
@property (nonatomic) double activatedAt;
@property (nonatomic) NSUInteger navIndex;          // reach: next nav in the list
@property (nonatomic, copy) NSString *progress;     // shown after the text, e.g. "2/5"
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *scanTime;
@end

@interface Mission : NSObject

+ (NSArray<NSDictionary *> *)all;               // the campaign, in order
+ (NSDictionary *)missionAtIndex:(NSUInteger)i;
+ (NSUInteger)unlockedCount;                    // persisted progress, at least 1
+ (void)markCompleted:(NSUInteger)index;
+ (NSArray<Objective *> *)objectivesFor:(NSDictionary *)mission;

@end

static inline simd_float3 Vec3(NSArray *a) {
    return a.count >= 3 ? simd_make_float3([a[0] floatValue], [a[1] floatValue], [a[2] floatValue]) : simd_make_float3(0, 0, 0);
}
