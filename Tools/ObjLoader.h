#import <SceneKit/SceneKit.h>

// Build-time only (Tools/BakeModels.m): the game loads the baked .scn files.
// Minimal Wavefront OBJ reader for the meshes Blender exports for this game.
// Unlike SceneKit's importer (which merges everything into one mesh), it
// returns one node per "o" object, named after it, with one geometry element
// per "usemtl" and placeholder materials carrying the material names.
@interface ObjLoader : NSObject

+ (NSArray<SCNNode *> *)nodesFromURL:(NSURL *)url;

@end
