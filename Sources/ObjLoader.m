#import "ObjLoader.h"
#import <simd/simd.h>

typedef struct { int v, t, n; } Corner;

@implementation ObjLoader

// One object's faces, split by material, with corners deduplicated into a
// shared vertex buffer.
static SCNNode *BuildNode(NSString *name, NSArray<NSString *> *mats, NSArray<NSMutableData *> *tris,
                          const simd_float3 *pos, const simd_float2 *uv, const simd_float3 *nrm) {
    NSMutableDictionary<NSValue *, NSNumber *> *index = [NSMutableDictionary dictionary];
    NSMutableData *vp = [NSMutableData data], *vt = [NSMutableData data], *vn = [NSMutableData data];
    NSMutableArray<SCNGeometryElement *> *elements = [NSMutableArray array];
    NSMutableArray<SCNMaterial *> *materials = [NSMutableArray array];
    uint32_t count = 0;
    for (NSUInteger m = 0; m < mats.count; m++) {
        NSMutableData *corners = tris[m];
        NSUInteger n = corners.length / sizeof(Corner);
        if (!n) continue;
        const Corner *cs = corners.bytes;
        NSMutableData *idx = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
        uint32_t *ip = idx.mutableBytes;
        for (NSUInteger i = 0; i < n; i++) {
            Corner c = cs[i];
            NSValue *key = [NSValue valueWithBytes:&c objCType:@encode(Corner)];
            NSNumber *found = index[key];
            if (!found) {
                simd_float3 p = pos[c.v];
                simd_float2 t = c.t >= 0 ? uv[c.t] : simd_make_float2(0, 0);
                simd_float3 nn = c.n >= 0 ? nrm[c.n] : simd_make_float3(0, 1, 0);
                float pf[3] = { p.x, p.y, p.z }, tf[2] = { t.x, 1.0f - t.y }, nf[3] = { nn.x, nn.y, nn.z };
                [vp appendBytes:pf length:sizeof pf];
                [vt appendBytes:tf length:sizeof tf];
                [vn appendBytes:nf length:sizeof nf];
                found = @(count++);
                index[key] = found;
            }
            ip[i] = found.unsignedIntValue;
        }
        [elements addObject:[SCNGeometryElement geometryElementWithData:idx primitiveType:SCNGeometryPrimitiveTypeTriangles
                                                         primitiveCount:n / 3 bytesPerIndex:sizeof(uint32_t)]];
        SCNMaterial *mat = [SCNMaterial material];
        mat.name = mats[m];
        [materials addObject:mat];
    }
    if (!elements.count) return nil;
    SCNGeometrySource *sp = [SCNGeometrySource geometrySourceWithData:vp semantic:SCNGeometrySourceSemanticVertex vectorCount:count
                                                      floatComponents:YES componentsPerVector:3 bytesPerComponent:4 dataOffset:0 dataStride:12];
    SCNGeometrySource *st = [SCNGeometrySource geometrySourceWithData:vt semantic:SCNGeometrySourceSemanticTexcoord vectorCount:count
                                                      floatComponents:YES componentsPerVector:2 bytesPerComponent:4 dataOffset:0 dataStride:8];
    SCNGeometrySource *sn = [SCNGeometrySource geometrySourceWithData:vn semantic:SCNGeometrySourceSemanticNormal vectorCount:count
                                                      floatComponents:YES componentsPerVector:3 bytesPerComponent:4 dataOffset:0 dataStride:12];
    SCNGeometry *g = [SCNGeometry geometryWithSources:@[sp, st, sn] elements:elements];
    g.materials = materials;
    SCNNode *node = [SCNNode nodeWithGeometry:g];
    node.name = name;
    return node;
}

+ (NSArray<SCNNode *> *)nodesFromURL:(NSURL *)url {
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    if (!data) return @[];
    NSMutableData *pos = [NSMutableData data], *uv = [NSMutableData data], *nrm = [NSMutableData data];
    NSMutableArray<SCNNode *> *nodes = [NSMutableArray array];
    __block NSString *object = @"Object";
    NSMutableArray<NSString *> *mats = [NSMutableArray array];
    NSMutableArray<NSMutableData *> *tris = [NSMutableArray array];
    __block NSInteger current = -1;

    void (^flush)(void) = ^{
        SCNNode *n = BuildNode(object, mats, tris, pos.bytes, uv.bytes, nrm.bytes);
        if (n) [nodes addObject:n];
        [mats removeAllObjects];
        [tris removeAllObjects];
        current = -1;
    };

    const char *p = data.bytes, *end = p + data.length;
    char word[256];
    while (p < end) {
        const char *eol = memchr(p, '\n', end - p) ?: end;
        size_t len = (size_t)(eol - p);
        if (len >= 2) {
            if (p[0] == 'v' && p[1] == ' ') {
                float f[3] = { 0 }; sscanf(p + 2, "%f %f %f", &f[0], &f[1], &f[2]);
                simd_float3 v = simd_make_float3(f[0], f[1], f[2]);
                [pos appendBytes:&v length:sizeof v];
            } else if (p[0] == 'v' && p[1] == 't') {
                float f[2] = { 0 }; sscanf(p + 3, "%f %f", &f[0], &f[1]);
                simd_float2 v = simd_make_float2(f[0], f[1]);
                [uv appendBytes:&v length:sizeof v];
            } else if (p[0] == 'v' && p[1] == 'n') {
                float f[3] = { 0 }; sscanf(p + 3, "%f %f %f", &f[0], &f[1], &f[2]);
                simd_float3 v = simd_make_float3(f[0], f[1], f[2]);
                [nrm appendBytes:&v length:sizeof v];
            } else if (p[0] == 'o' && p[1] == ' ') {
                if (mats.count) flush();
                size_t n = MIN(len - 2, sizeof word - 1);
                memcpy(word, p + 2, n); word[n] = 0;
                object = [[NSString stringWithUTF8String:word] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            } else if (!strncmp(p, "usemtl ", 7)) {
                size_t n = MIN(len - 7, sizeof word - 1);
                memcpy(word, p + 7, n); word[n] = 0;
                NSString *name = [[NSString stringWithUTF8String:word] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                NSUInteger i = [mats indexOfObject:name];
                if (i == NSNotFound) { [mats addObject:name]; [tris addObject:[NSMutableData data]]; i = mats.count - 1; }
                current = (NSInteger)i;
            } else if (p[0] == 'f' && p[1] == ' ') {
                if (current < 0) { [mats addObject:@"Default"]; [tris addObject:[NSMutableData data]]; current = (NSInteger)mats.count - 1; }
                // Corners "v/t/n", "v//n" or "v"; polygons are fanned.
                Corner cs[64];
                int nc = 0;
                const char *q = p + 2;
                while (q < eol && nc < 64) {
                    while (q < eol && *q == ' ') q++;
                    if (q >= eol || *q == '\r') break;
                    Corner c = { -1, -1, -1 };
                    c.v = (int)strtol(q, (char **)&q, 10) - 1;
                    if (*q == '/') {
                        q++;
                        if (*q != '/') c.t = (int)strtol(q, (char **)&q, 10) - 1;
                        if (*q == '/') { q++; c.n = (int)strtol(q, (char **)&q, 10) - 1; }
                    }
                    cs[nc++] = c;
                    while (q < eol && *q != ' ') q++;
                }
                NSMutableData *out = tris[(NSUInteger)current];
                for (int i = 1; i + 1 < nc; i++) {
                    [out appendBytes:&cs[0] length:sizeof(Corner)];
                    [out appendBytes:&cs[i] length:sizeof(Corner)];
                    [out appendBytes:&cs[i + 1] length:sizeof(Corner)];
                }
            }
        }
        p = eol + 1;
    }
    if (mats.count) flush();
    return nodes;
}

@end
