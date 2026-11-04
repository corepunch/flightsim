// Bakes Wavefront OBJ meshes into SceneKit binary scenes (.scn) that
// ObjLoader loads instead of parsing text. Run by build.sh:
//   BakeModels <out-dir> <in.obj>...   writes <out-dir>/<name>.scn
// With --verify it reloads each .scn and checks it matches the OBJ exactly
// (node names, material names, vertex and index data).
#import <SceneKit/SceneKit.h>
#import "ObjLoader.h"

static NSData *Fingerprint(NSArray<SCNNode *> *nodes) {
    NSMutableData *d = [NSMutableData data];
    for (SCNNode *n in nodes) {
        [d appendData:[n.name dataUsingEncoding:NSUTF8StringEncoding]];
        for (SCNMaterial *m in n.geometry.materials) [d appendData:[m.name dataUsingEncoding:NSUTF8StringEncoding]];
        for (SCNGeometrySource *s in n.geometry.geometrySources) {
            [d appendData:[s.semantic dataUsingEncoding:NSUTF8StringEncoding]];
            [d appendData:s.data];
        }
        for (SCNGeometryElement *e in n.geometry.geometryElements) [d appendData:e.data];
    }
    return d;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int i = 1;
        BOOL verify = argc > i && !strcmp(argv[i], "--verify");
        if (verify) i++;
        if (argc - i < 2) {
            fprintf(stderr, "usage: BakeModels [--verify] <out-dir> <in.obj>...\n");
            return 2;
        }
        NSString *outDir = @(argv[i++]);
        [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        int failures = 0;
        for (; i < argc; i++) {
            NSURL *obj = [NSURL fileURLWithPath:@(argv[i])];
            NSString *name = obj.URLByDeletingPathExtension.lastPathComponent;
            NSURL *scn = [NSURL fileURLWithPath:[[outDir stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"scn"]];
            NSArray<SCNNode *> *nodes = [ObjLoader nodesFromOBJURL:obj];
            if (!nodes.count || ![ObjLoader writeNodes:nodes toSCNURL:scn]) {
                fprintf(stderr, "BakeModels: failed on %s\n", argv[i]);
                failures++;
                continue;
            }
            if (verify) {
                NSArray *back = [SCNScene sceneWithURL:scn options:nil error:nil].rootNode.childNodes;
                if (![Fingerprint(back) isEqualToData:Fingerprint(nodes)]) {
                    fprintf(stderr, "BakeModels: %s.scn differs from the OBJ\n", name.UTF8String);
                    failures++;
                }
            }
        }
        return failures ? 1 : 0;
    }
}
