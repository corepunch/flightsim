// Bakes the Wavefront OBJ sources in Resources/Models into SceneKit binary
// scenes (.scn), the format the game loads. Run by build.sh:
//
//   BakeModels [--scenekit] <out-dir> <in.obj>...    writes <out-dir>/<name>.scn
//
// Default ("parts") reads the OBJ with ObjLoader: one node per "o" object,
// named after it, with per-usemtl elements, named materials and tangents.
// Capital ships and the cockpit need that (subsystems are found by name).
// --scenekit uses SceneKit's own importer instead, for the fighter meshes,
// which are used as one plain geometry.
//
// Every scene is read back and compared with the OBJ result (node names,
// material names, vertex and index data); any difference fails the bake.
#import <SceneKit/SceneKit.h>
#import "ObjLoader.h"

static NSData *Fingerprint(SCNNode *root) {
    NSMutableData *d = [NSMutableData data];
    [root enumerateHierarchyUsingBlock:^(SCNNode *n, BOOL *stop) {
        if (!n.geometry) return;
        [d appendData:[n.name ?: @"" dataUsingEncoding:NSUTF8StringEncoding]];
        for (SCNMaterial *m in n.geometry.materials) [d appendData:[m.name ?: @"" dataUsingEncoding:NSUTF8StringEncoding]];
        // Per-vector values, not raw buffers: archiving may de-interleave
        // sources (SceneKit's OBJ importer shares one strided buffer).
        for (SCNGeometrySource *s in n.geometry.geometrySources) {
            [d appendData:[s.semantic dataUsingEncoding:NSUTF8StringEncoding]];
            NSUInteger size = (NSUInteger)(s.componentsPerVector * s.bytesPerComponent);
            const uint8_t *bytes = s.data.bytes;
            for (NSInteger v = 0; v < s.vectorCount; v++) {
                NSUInteger at = (NSUInteger)(s.dataOffset + v * s.dataStride);
                if (at + size > s.data.length) break;
                [d appendBytes:bytes + at length:size];
            }
        }
        for (SCNGeometryElement *e in n.geometry.geometryElements) [d appendData:e.data];
    }];
    return d;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int i = 1;
        BOOL scenekit = argc > i && !strcmp(argv[i], "--scenekit");
        if (scenekit) i++;
        if (argc - i < 2) {
            fprintf(stderr, "usage: BakeModels [--scenekit] <out-dir> <in.obj>...\n");
            return 2;
        }
        NSString *outDir = @(argv[i++]);
        [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        int failures = 0;
        for (; i < argc; i++) {
            @autoreleasepool {
                NSURL *obj = [NSURL fileURLWithPath:@(argv[i])];
                NSString *name = obj.URLByDeletingPathExtension.lastPathComponent;
                NSURL *scn = [NSURL fileURLWithPath:[[outDir stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"scn"]];

                SCNScene *scene;
                if (scenekit) {
                    scene = [SCNScene sceneWithURL:obj options:nil error:nil];
                } else {
                    scene = [SCNScene scene];
                    for (SCNNode *n in [ObjLoader nodesFromURL:obj]) [scene.rootNode addChildNode:n];
                }
                NSData *expected = Fingerprint(scene.rootNode);
                if (!scene || !expected.length || ![scene writeToURL:scn options:nil delegate:nil progressHandler:nil]) {
                    fprintf(stderr, "BakeModels: failed on %s\n", argv[i]);
                    failures++;
                    continue;
                }
                SCNScene *back = [SCNScene sceneWithURL:scn options:nil error:nil];
                if (![Fingerprint(back.rootNode) isEqualToData:expected]) {
                    fprintf(stderr, "BakeModels: %s.scn does not match its OBJ\n", name.UTF8String);
                    [[NSFileManager defaultManager] removeItemAtURL:scn error:nil];
                    failures++;
                }
            }
        }
        return failures ? 1 : 0;
    }
}
