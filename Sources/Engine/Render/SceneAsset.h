#import <SceneKit/SceneKit.h>

// Loads a baked model, Resources/Models/<subdirectory>/<name>.scn (made from
// the .obj sources by build.sh / Tools/BakeModels.m), and returns its
// top-level nodes, detached so they can go straight into another scene.
// Empty if the file is missing or unreadable.
static inline NSArray<SCNNode *> *SceneAssetNodes(NSString *name, NSString *subdirectory) {
    NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"scn" subdirectory:subdirectory];
    if (!url) return @[];
    NSError *error = nil;
    SCNScene *scene = [SCNScene sceneWithURL:url options:nil error:&error];
    if (!scene) {
        NSLog(@"SceneAsset: %@.scn unreadable: %@", name, error.localizedDescription);
        return @[];
    }
    NSArray<SCNNode *> *nodes = [scene.rootNode.childNodes copy];
    for (SCNNode *n in nodes) [n removeFromParentNode];
    return nodes;
}
