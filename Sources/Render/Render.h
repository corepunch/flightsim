#pragma once

#import <SceneKit/SceneKit.h>
#import <simd/simd.h>
#import <TargetConditionals.h>
#import <Foundation/Foundation.h>
#import <SpriteKit/SpriteKit.h>
#import <Metal/Metal.h>
#import "Collision.h"
#include "Shared.h"
#import "Shared.h"
#import "Refresh.h"

// MARK: - Scene visibility

// SceneKit nodes default to the geometry category. Sky decoration remains
// visible to cameras but does not participate in world visibility queries.
typedef NS_OPTIONS(NSUInteger, RenderCategory) {
    RenderCategoryGeometry = 1 << 0,
    RenderCategoryBackground = 1 << 1,
};

// MARK: - CapitalView

// What a capital ship, station, prop or rock looks like: a clone of the
// asset's parts dressed in its style's hull materials. Destroyed subsystems
// are hidden by part index (EntityState.deadParts).
@interface CapitalView : NSObject

+ (instancetype)viewWithModel:(NSString *)model;       // "cap:<asset>:<style>"
- (instancetype)initWithAsset:(NSString *)asset style:(NSString *)style;
+ (SCNNode *)prototypeForAsset:(NSString *)asset style:(NSString *)style;
+ (void)updateSharedMaterials:(double)time;             // running lights blink, shields pulse

@property (nonatomic, readonly) SCNNode *node;
@property (nonatomic, readonly) SCNNode *body;
@property (nonatomic, readonly) ModelInfo *info;
@property (nonatomic, readonly) NSArray<SCNNode *> *parts;
@property (nonatomic) uint64_t deadParts;

- (NSUInteger)countParts:(SubsystemKind)kind alive:(BOOL)aliveOnly;

@end

// MARK: - PlatformImage

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
typedef UIImage PlatformImage;
typedef UIFont PlatformFont;
#else
#import <AppKit/AppKit.h>
typedef NSImage PlatformImage;
typedef NSFont PlatformFont;
#endif

// MARK: - RenderTextures

// Shares decoded 3D textures across material slots and applies the configured
// texture budget before an image is expanded into CPU or GPU memory.
@interface RenderTextures : NSObject
+ (id)contentsOfURL:(NSURL *)url sRGB:(BOOL)sRGB;
+ (void)printStats;
@end

static inline PlatformImage *PlatformImageFromCGImage(CGImageRef image) {
#if TARGET_OS_IOS
    return [UIImage imageWithCGImage:image];
#else
    return [[NSImage alloc] initWithCGImage:image size:NSZeroSize];
#endif
}

static inline CGImageRef PlatformImageCGImage(PlatformImage *image) {
#if TARGET_OS_IOS
    return image.CGImage;
#else
    return [image CGImageForProposedRect:NULL context:nil hints:nil];
#endif
}

static inline PlatformImage *PlatformDrawImage(CGSize size, void (^draw)(CGContextRef, CGRect)) {
#if TARGET_OS_IOS
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        draw(context.CGContext, CGRectMake(0, 0, size.width, size.height));
    }];
#else
    return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        draw(NSGraphicsContext.currentContext.CGContext, rect);
        return YES;
    }];
#endif
}

// MARK: - Exhaust

// Engine exhaust for one ship: per nozzle a flame cone (shader-driven, with
// flicker and shock diamonds) plus particle "fumes": a hot plasma plume that
// stays attached to the nozzle and a smoke trail left behind in world space.
// Flame length, brightness and particle output all scale with throttle.
@interface Exhaust : NSObject

// nozzles: x,y,z = position in ship space (ship forward is -Z), w = radius.
- (instancetype)initWithNozzles:(const simd_float4 *)nozzles count:(NSUInteger)count
                          color:(simd_float3)color parent:(SCNNode *)parent smoke:(BOOL)smoke;

- (void)updateThrottle:(float)throttle boost:(BOOL)boost dt:(float)dt;
- (void)setEnabled:(BOOL)enabled;

@property (nonatomic, readonly) float level; // smoothed 0..~1.6

+ (PlatformImage *)softDotImage;
+ (PlatformImage *)streakImage;      // anamorphic streak, zero alpha on all edges
// Resources/Particles/<name>.png. Names joined with "+" ("flame_01+flame_02")
// give a square atlas of those sprites, for an image sequence.
+ (PlatformImage *)particleTexture:(NSString *)name;
// The texture for alpha-blended particle systems: straight (unpremultiplied)
// alpha, since SceneKit multiplies their colour by alpha again, and coverage
// that fades out with brightness, since sprites drawn on opaque black would
// otherwise carry a black fringe. Brightness stays as shading.
+ (PlatformImage *)straightAlphaParticleTexture:(NSString *)name;

@end

// MARK: - ShipView

// Soft-knee roll-off on a lit hull's reflected light (emission untouched),
// so sun, engine glow and explosion flashes can't push the plating past the
// display range and turn the ship into a featureless white shape.
// Emitters retain their separate coloured glow geometry.
void ApplyHullRolloff(SCNMaterial *m);

// What a ship looks like, from its definition: hull mesh, engine exhaust,
// shield bubble and damage fire/smoke. No physics: the game flies ships,
// this draws them.
@interface ShipView : NSObject

+ (instancetype)shipWithDefinition:(const ShipDef *)definition smoke:(BOOL)smoke;
+ (instancetype)viewWithModel:(NSString *)model;          // "ship:<definition>", nil if unknown
+ (SCNGeometry *)geometryForDefinition:(const ShipDef *)definition;   // shared, OBJ space (+Z nose)

@property (nonatomic, readonly) SCNNode *node;     // forward is -Z
@property (nonatomic, readonly) SCNNode *model;
@property (nonatomic, readonly) Exhaust *exhaust;
@property (nonatomic, readonly) const ShipDef *definition;
@property (nonatomic, readonly) float radius;

- (void)updateThrottle:(float)throttle boost:(BOOL)boost hull:(float)hull alive:(BOOL)alive dt:(float)dt;
- (void)flashShieldFrom:(simd_float3)direction;   // toward the hit, in ship space
- (void)setAlive:(BOOL)alive;

@end

// MARK: - Cockpit

// The player's cockpit: Resources/Models/Cockpit.scn, baked from Cockpit.obj (built by
// Art/build_cockpit.py) with live SpriteKit scenes on its displays and
// emissive annunciators. Screens and lamps are found by material name.
@interface Cockpit : NSObject

@property (nonatomic, readonly) SCNNode *node;   // origin is the pilot's eye
// Fixed-resolution glass instruments, also rendered by the standalone UI catalogue.
@property (nonatomic, readonly) NSDictionary<NSString *, SKScene *> *displayScenes;

- (instancetype)initWithDevice:(id<MTLDevice>)device;
// Renders the displays into their textures; call before the frame renders.
- (void)renderDisplaysWithQueue:(id<MTLCommandQueue>)queue time:(NSTimeInterval)time;

- (void)updateFrame:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count;
// The player's own ship, for the status display's hologram (OBJ space, +Z nose).
- (void)setSelfGeometry:(SCNGeometry *)geometry;

@end

// MARK: - Effects

// Film-style space combat effects, layered the way Star Wars games and films
// build them: blaster bolts with a white-hot core inside a coloured glow,
// pooled muzzle flashes, shader-driven "hot
// sphere" impacts, and explosions built from layered sprite particles (flash,
// fire, a smoke shroud, and burning fragments that trail fire and smoke).
@interface Effects : NSObject

- (instancetype)initWithScene:(SCNScene *)scene;

// Bolt prototype: node whose children are a core and a glow capsule along +Y.
- (SCNNode *)makeBoltNode;
- (void)styleBolt:(SCNNode *)bolt player:(BOOL)player ion:(BOOL)ion;

- (void)muzzleFlashOn:(SCNNode *)parent local:(simd_float3)local player:(BOOL)player;
- (void)impactAt:(simd_float3)p player:(BOOL)playerBolt shielded:(BOOL)shielded;
- (void)explosionAt:(simd_float3)p velocity:(simd_float3)v hullMaterial:(SCNMaterial *)hull;
- (void)explosionAt:(simd_float3)p velocity:(simd_float3)v hullMaterial:(SCNMaterial *)hull scale:(float)scale;

// Camera-facing horizontal lens streak (anamorphic flare look).
- (SCNNode *)streakWithColor:(SKColor *)color width:(float)width height:(float)height;

// Nodes using every effect material, for -[SCNView prepareObjects:].
- (NSArray<SCNNode *> *)warmupNodes;

+ (SCNMaterial *)additiveTextureMaterial:(NSString *)texture tint:(simd_float3)tint;

@end

// MARK: - FXRecorder

// Offline effect preview: renders one effect on a black background with the
// game camera settings at a fixed 60 fps timestep and encodes
// it to H.264 .mp4 (plus a contact-sheet .png of 12 frames next to it).
//
//   KestrelFrontier --record-fx explosion out.mp4 [seconds]
//   effects: explosion, impact, shield, bolt, exhaust, all
@interface FXRecorder : NSObject

+ (int)recordEffect:(NSString *)effect toFile:(NSString *)path seconds:(double)seconds;

@end

// MARK: - FlightInstruments

// Authored at 608 x 400; shared by the cockpit glass and chase-view HUD.
@interface TargetReadout : SKNode
- (instancetype)initWithPreview:(BOOL)preview;
- (void)setCompact:(BOOL)compact;
- (void)updateFrame:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count;
@end

// A hemisphere sensor: straight ahead/behind is centre; abeam is the rim.
@interface SensorScope : SKNode
- (instancetype)initRear:(BOOL)rear;
- (void)updateFrame:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count;
// The disc, in the parent's coordinates: what neighbours lay out against,
// since blips and labels can reach past it.
@property (nonatomic, readonly) CGRect discFrame;
@end

// MARK: - LensFlare

// Camera optics in view points: sun core, halo, aperture rays and reflections.
// The shader supplies glare directly in the display range, without camera bloom.
// The caller supplies visibility after testing the light against scene geometry.
@interface LensFlare : SKNode
- (void)updateSource:(CGPoint)source visibility:(CGFloat)visibility
           viewport:(CGSize)viewport deltaTime:(NSTimeInterval)dt;
@end

// MARK: - SceneKitRefresh

// The Refresh backend on SceneKit: one SCNScene holding the sky, sun, camera,
// the player's ship rig and cockpit, the world's entity nodes and the effect
// pools. Only the platform glue (Host, FXRecorder) knows this class; the
// client talks to it through <Refresh>.
@interface SceneKitRefresh : NSObject <Refresh>
- (void)printStats;

// `renderer` is the view (or offscreen renderer) the scene is drawn with; it
// projects points and uploads to the GPU. `size` is used when it is not a
// view.
- (instancetype)initWithRenderer:(id<SCNSceneRenderer>)renderer size:(CGSize)size;

// Load queue, instead of -buildWorld: a black studio with a neutral key and
// fill light and no sky, for effect previews (--record-fx).
- (void)buildStudio;

@property (nonatomic, readonly) SCNScene *scene;
@property (nonatomic, readonly) SCNNode *cameraNode;

@end

// MARK: - SpaceSky

// A vertex-coloured nebula mesh with shader stars and an analytic planet.
// The sky and dust follow the camera without allocating sky textures.
@interface SpaceSky : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device seed:(uint32_t)seed;

@property (nonatomic, readonly) SCNNode *node;
@property (nonatomic, readonly) simd_float3 sunDirection;    // toward the sun
@property (nonatomic, readonly) simd_float3 planetDirection;

// Infinite field of dust streaks that wraps around the camera.
- (SCNNode *)makeDustNode;
- (void)updateDust:(SCNNode *)dust cameraPosition:(simd_float3)cameraPosition velocity:(simd_float3)velocity;

@end

// MARK: - ProceduralTerrain

// A landscape evaluated entirely on the GPU: geometry-clipmap rings of one shared grid
// follow the camera, and Resources/Shaders/Terrain*.metal compute height, cover
// (water, roads, villages, fields, forest, rock), lighting and a cloud sky dome from
// noise. There are no height or colour maps; a level only switches it on.
@interface ProceduralTerrain : NSObject

// Compiles TerrainCommon.metal and Terrain.metal from the directory (nil on failure).
+ (id<MTLLibrary>)libraryWithDevice:(id<MTLDevice>)device shaderDirectory:(NSURL *)directory;

// cells: vertices per ring edge, a multiple of 4 up to 252; more is finer and costlier.
- (instancetype)initWithLibrary:(id<MTLLibrary>)library cells:(NSUInteger)cells hdr:(BOOL)hdr;

@property (nonatomic, readonly) SCNNode *node;        // the clipmap rings
@property (nonatomic, readonly) SCNNode *skyNode;     // the dome; follows the camera
@property (nonatomic) simd_float3 sunDirection;       // toward the sun
@property (nonatomic) LevelEnvironment environment;   // fog colour and range

// Recentres the rings and picks the finest ring for the camera's height.
- (void)updateForCamera:(simd_float3)position time:(double)time;
- (NSString *)stats;

@end
