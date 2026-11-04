#import "ModelInfo.h"
#import "SceneAsset.h"

@implementation ModelInfo {
    SCNNode *_root;                     // the parts, for hit tests (never in a scene)
    GameModelInfo _info;
    NSMapTable<SCNNode *, NSNumber *> *_partOfNode;
}

+ (int)partKindForName:(NSString *)name {
    if ([name hasPrefix:@"Turret_"]) return SubsystemTurret;
    if ([name hasPrefix:@"Engine_"]) return SubsystemEngine;
    if ([name hasPrefix:@"Shield_"]) return SubsystemShield;
    if ([name hasPrefix:@"Core_"]) return SubsystemCore;
    return -1;
}

+ (ModelInfo *)capitalAsset:(NSString *)asset {
    static NSMutableDictionary<NSString *, ModelInfo *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    // One lock for the whole load: two queues asking for the same asset wait
    // for one parse instead of doing it twice.
    @synchronized (cache) {
        ModelInfo *m = cache[asset];
        if (!m) cache[asset] = m = [[ModelInfo alloc] initWithAsset:asset];
        return m;
    }
}

- (instancetype)initWithAsset:(NSString *)asset {
    if ((self = [super init])) {
        _asset = [asset copy];
        NSArray<SCNNode *> *parts = SceneAssetNodes(asset, @"Models/Capital");
        if (!parts.count) {
            NSLog(@"ModelInfo: missing asset %@", asset);
            SCNNode *box = [SCNNode nodeWithGeometry:[SCNBox boxWithWidth:20 height:20 length:60 chamferRadius:2]];
            box.name = @"Body";
            parts = @[box];
        }
        _nodes = parts;
        _root = [SCNNode node];
        _partOfNode = [NSMapTable weakToStrongObjectsMapTable];
        for (SCNNode *n in parts) {
            SCNNode *copy = [SCNNode nodeWithGeometry:n.geometry];
            copy.name = n.name;
            copy.simdTransform = n.simdTransform;
            [_root addChildNode:copy];
            int kind = [ModelInfo partKindForName:n.name];
            if (kind < 0 || _info.numParts >= MAX_PARTS) continue;
            SCNVector3 lo, hi;
            [copy getBoundingBoxMin:&lo max:&hi];
            simd_float3 c = simd_make_float3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2);
            c = simd_mul(copy.simdTransform, simd_make_float4(c, 1)).xyz;
            _info.parts[_info.numParts].kind = (uint8_t)kind;
            _info.parts[_info.numParts].center = c;
            [_partOfNode setObject:@(_info.numParts) forKey:copy];
            _info.numParts++;
        }
        SCNVector3 lo, hi;
        [_root getBoundingBoxMin:&lo max:&hi];
        simd_float3 a = simd_make_float3(lo.x, lo.y, lo.z), b = simd_make_float3(hi.x, hi.y, hi.z);
        _radius = _info.radius = fmaxf(simd_length(a), simd_length(b));
    }
    return self;
}

- (const GameModelInfo *)info { return &_info; }

- (BOOL)traceFrom:(simd_float3)a to:(simd_float3)b deadParts:(uint64_t)deadParts
            point:(simd_float3 *)point part:(int *)part {
    NSArray<SCNHitTestResult *> *hits = [_root hitTestWithSegmentFromPoint:SCNVector3Make(a.x, a.y, a.z)
                                                                   toPoint:SCNVector3Make(b.x, b.y, b.z)
                                                                   options:@{ SCNHitTestOptionSearchMode : @(SCNHitTestSearchModeAll),
                                                                              SCNHitTestBackFaceCullingKey : @NO }];
    float best = FLT_MAX;
    BOOL found = NO;
    for (SCNHitTestResult *h in hits) {
        NSNumber *p = [_partOfNode objectForKey:h.node];
        if (p && (deadParts & (1ull << p.intValue))) continue;   // destroyed: gone from the hull
        SCNVector3 w = h.localCoordinates;
        simd_float3 local = simd_mul(h.node.simdTransform, simd_make_float4(w.x, w.y, w.z, 1)).xyz;
        float d = simd_distance_squared(local, a);
        if (d >= best) continue;
        best = d;
        *point = local;
        *part = p ? p.intValue : -1;
        found = YES;
    }
    return found;
}

@end
