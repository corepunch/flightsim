#import "ObjLoader.h"
#import <simd/simd.h>

typedef struct { int v, t, n; } Corner;

// Reads up to n floats starting at p. strtof stops at the first character
// that isn't part of a number, so it never scans past the line (sscanf would
// strlen the whole rest of the file on every call: quadratic on big OBJs).
static void ReadFloats(const char *p, const char *eol, float *out, int n) {
    for (int i = 0; i < n && p < eol; i++) {
        char *next;
        float v = strtof(p, &next);
        if (next == p || next > eol) break;
        out[i] = v;
        p = next;
    }
}

@implementation ObjLoader

// One object's faces, split by material. Every triangle corner becomes its
// own vertex (no dedupe: fast and simple), which also lets each triangle
// carry its own tangent for normal mapping.
static SCNNode *BuildNode(NSString *name, NSArray<NSString *> *mats, NSArray<NSMutableData *> *tris,
                          const simd_float3 *pos, const simd_float2 *uv, const simd_float3 *nrm) {
    NSUInteger total = 0;
    for (NSMutableData *d in tris) total += d.length / sizeof(Corner);
    if (!total) return nil;
    NSMutableData *vp = [NSMutableData dataWithLength:total * 12], *vt = [NSMutableData dataWithLength:total * 8];
    NSMutableData *vn = [NSMutableData dataWithLength:total * 12], *vg = [NSMutableData dataWithLength:total * 16];
    float *P = vp.mutableBytes, *T = vt.mutableBytes, *N = vn.mutableBytes, *G = vg.mutableBytes;
    NSMutableArray<SCNGeometryElement *> *elements = [NSMutableArray array];
    NSMutableArray<SCNMaterial *> *materials = [NSMutableArray array];
    uint32_t count = 0;
    for (NSUInteger m = 0; m < mats.count; m++) {
        NSUInteger n = tris[m].length / sizeof(Corner);
        if (!n) continue;
        const Corner *cs = tris[m].bytes;
        NSMutableData *idx = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
        uint32_t *ip = idx.mutableBytes;
        for (NSUInteger i = 0; i + 2 < n; i += 3) {
            simd_float3 p[3];
            simd_float2 t[3];
            for (int k = 0; k < 3; k++) {
                Corner c = cs[i + k];
                p[k] = pos[c.v];
                t[k] = c.t >= 0 ? uv[c.t] : simd_make_float2(0, 0);
                simd_float3 nn = c.n >= 0 ? nrm[c.n] : simd_make_float3(0, 1, 0);
                uint32_t v = count + (uint32_t)k;
                P[v * 3] = p[k].x; P[v * 3 + 1] = p[k].y; P[v * 3 + 2] = p[k].z;
                T[v * 2] = t[k].x; T[v * 2 + 1] = 1.0f - t[k].y;
                N[v * 3] = nn.x; N[v * 3 + 1] = nn.y; N[v * 3 + 2] = nn.z;
                ip[i + k] = v;
            }
            // Tangent along +U (texture right), with handedness in w.
            simd_float3 e1 = p[1] - p[0], e2 = p[2] - p[0];
            simd_float2 d1 = t[1] - t[0], d2 = t[2] - t[0];
            float det = d1.x * d2.y - d2.x * d1.y;
            simd_float3 tan = fabsf(det) > 1e-12f ? (e1 * d2.y - e2 * d1.y) / det : e1;
            simd_float3 bit = fabsf(det) > 1e-12f ? (e2 * d1.x - e1 * d2.x) / det : e2;
            for (int k = 0; k < 3; k++) {
                uint32_t v = count + (uint32_t)k;
                simd_float3 nn = simd_make_float3(N[v * 3], N[v * 3 + 1], N[v * 3 + 2]);
                simd_float3 tt = tan - nn * simd_dot(nn, tan);
                tt = simd_length(tt) > 1e-8f ? simd_normalize(tt) : simd_make_float3(1, 0, 0);
                // The V flip above mirrors the texture vertically, so the
                // handedness flips too.
                float w = simd_dot(simd_cross(nn, tt), bit) < 0 ? 1.0f : -1.0f;
                G[v * 4] = tt.x; G[v * 4 + 1] = tt.y; G[v * 4 + 2] = tt.z; G[v * 4 + 3] = w;
            }
            count += 3;
        }
        [elements addObject:[SCNGeometryElement geometryElementWithData:idx primitiveType:SCNGeometryPrimitiveTypeTriangles
                                                         primitiveCount:n / 3 bytesPerIndex:sizeof(uint32_t)]];
        SCNMaterial *mat = [SCNMaterial material];
        mat.name = mats[m];
        [materials addObject:mat];
    }
    SCNGeometrySource *sp = [SCNGeometrySource geometrySourceWithData:vp semantic:SCNGeometrySourceSemanticVertex vectorCount:count
                                                      floatComponents:YES componentsPerVector:3 bytesPerComponent:4 dataOffset:0 dataStride:12];
    SCNGeometrySource *st = [SCNGeometrySource geometrySourceWithData:vt semantic:SCNGeometrySourceSemanticTexcoord vectorCount:count
                                                      floatComponents:YES componentsPerVector:2 bytesPerComponent:4 dataOffset:0 dataStride:8];
    SCNGeometrySource *sn = [SCNGeometrySource geometrySourceWithData:vn semantic:SCNGeometrySourceSemanticNormal vectorCount:count
                                                      floatComponents:YES componentsPerVector:3 bytesPerComponent:4 dataOffset:0 dataStride:12];
    SCNGeometrySource *sg = [SCNGeometrySource geometrySourceWithData:vg semantic:SCNGeometrySourceSemanticTangent vectorCount:count
                                                      floatComponents:YES componentsPerVector:4 bytesPerComponent:4 dataOffset:0 dataStride:16];
    SCNGeometry *g = [SCNGeometry geometryWithSources:@[sp, st, sn, sg] elements:elements];
    g.materials = materials;
    SCNNode *node = [SCNNode nodeWithGeometry:g];
    node.name = name;
    return node;
}

+ (NSArray<SCNNode *> *)nodesFromURL:(NSURL *)url {
    NSURL *baked = [[url URLByDeletingPathExtension] URLByAppendingPathExtension:@"scn"];
    if (baked && [baked checkResourceIsReachableAndReturnError:nil]) {
        NSError *error = nil;
        SCNScene *scene = [SCNScene sceneWithURL:baked options:nil error:&error];
        if (scene) {
            NSArray<SCNNode *> *nodes = [scene.rootNode.childNodes copy];
            for (SCNNode *n in nodes) [n removeFromParentNode];
            return nodes;
        }
        NSLog(@"ObjLoader: %@ unreadable (%@), parsing the OBJ", baked.lastPathComponent, error.localizedDescription);
    }
    return [self nodesFromOBJURL:url];
}

+ (BOOL)writeNodes:(NSArray<SCNNode *> *)nodes toSCNURL:(NSURL *)url {
    SCNScene *scene = [SCNScene scene];
    for (SCNNode *n in nodes) [scene.rootNode addChildNode:n];
    BOOL ok = [scene writeToURL:url options:nil delegate:nil progressHandler:nil];
    for (SCNNode *n in nodes) [n removeFromParentNode];
    return ok;
}

+ (NSArray<SCNNode *> *)nodesFromOBJURL:(NSURL *)url {
    NSMutableData *data = url ? [NSMutableData dataWithContentsOfURL:url] : nil;
    if (!data) return @[];
    [data appendBytes:"" length:1];   // NUL guard so number parsing stops at the end
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

    const char *p = data.bytes, *end = p + data.length - 1;
    char word[256];
    while (p < end) {
        const char *eol = memchr(p, '\n', end - p) ?: end;
        size_t len = (size_t)(eol - p);
        if (len >= 2) {
            if (p[0] == 'v' && p[1] == ' ') {
                float f[3] = { 0 }; ReadFloats(p + 2, eol, f, 3);
                simd_float3 v = simd_make_float3(f[0], f[1], f[2]);
                [pos appendBytes:&v length:sizeof v];
            } else if (p[0] == 'v' && p[1] == 't') {
                float f[2] = { 0 }; ReadFloats(p + 3, eol, f, 2);
                simd_float2 v = simd_make_float2(f[0], f[1]);
                [uv appendBytes:&v length:sizeof v];
            } else if (p[0] == 'v' && p[1] == 'n') {
                float f[3] = { 0 }; ReadFloats(p + 3, eol, f, 3);
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
