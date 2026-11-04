#import <SceneKit/SceneKit.h>

// Minimal Wavefront OBJ reader for the meshes Blender exports for this game.
// Unlike SceneKit's importer (which merges everything into one mesh), it
// returns one node per "o" object, named after it, with one geometry element
// per "usemtl" and placeholder materials carrying the material names.
@interface ObjLoader : NSObject

// If a baked "<name>.scn" sits next to the .obj (build.sh makes them with
// Tools/BakeModels.m), that is loaded instead: same nodes, no parsing.
+ (NSArray<SCNNode *> *)nodesFromURL:(NSURL *)url;
// Always parses the OBJ text (what the baker uses).
+ (NSArray<SCNNode *> *)nodesFromOBJURL:(NSURL *)url;
// Archives nodes as a SceneKit binary scene that -nodesFromURL: will pick up.
+ (BOOL)writeNodes:(NSArray<SCNNode *> *)nodes toSCNURL:(NSURL *)url;

@end
