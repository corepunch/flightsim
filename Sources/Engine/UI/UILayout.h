#import <SpriteKit/SpriteKit.h>

// Screen layouts as data: Resources/UI/menus/<name>.json, read every time a
// screen lays itself out, so editing the file changes the next rebuild.
//
// A layout is a tree of nodes. Every node may have:
//   "id"        name for the screen's code to find its frame or items
//   "anchor"    [x, y] in the parent frame, 0..1 (default [0.5, 0.5])
//   "pivot"     [x, y] of the node's own frame placed at the anchor (default = anchor)
//   "offset"    [dx, dy] points
//   "size"      [w, h] points; a value <= 0 means the parent's size minus it
//   "margin"    [x, y]: the size never exceeds the parent's minus twice this
//   "inset"     [left, top, right, bottom]: the frame children are laid out in
//   "when"      { "<flag>": { …overrides… } } merged when the flag is set;
//               "compact" is set when the screen is shorter than the root's
//               "compactBelow" (or in portrait)
//   "children"  nodes, laid out in this node's (inset) frame
// and a "type":
//   "shade"     full-screen colour: "color" (theme name), "opacity"
//   "panel"     chamfered readout panel: "stroke"/"fill" as [color, opacity]
//   "label"     "text" (catalog key, or "$variable"), "font" (theme font
//               name), "fontSize", "color", "opacity", "align" left|center|right;
//               centred vertically in its frame
//   "buttons"   a vertical list of action buttons from "items" (each with
//               "id", "text", optional "disabled" and "when"), "rowHeight",
//               "gap"; rows shrink to fit the frame
//   "group"     nothing drawn; for positioning children
// Numbers anywhere can be replaced by { "compact": n, "regular": n }.

@interface UILayoutResult : NSObject
@property (nonatomic, readonly) SKNode *node;
// Frames (scene points) by id; buttons also register "<id>.<item id>".
@property (nonatomic, readonly) NSDictionary<NSString *, NSValue *> *frames;
// Buttons by "<list id>.<item id>", and the item ids of each list in order.
@property (nonatomic, readonly) NSDictionary<NSString *, SKNode *> *buttons;
@property (nonatomic, readonly) NSDictionary<NSString *, NSArray<NSString *> *> *lists;
@property (nonatomic, readonly) NSSet<NSString *> *disabled;   // "<list id>.<item id>"
- (CGRect)frame:(NSString *)name;   // CGRectNull when missing
@end

@interface UILayout : NSObject

// nil (and a log line) when the file is missing or unreadable.
+ (instancetype)named:(NSString *)name;

@property (nonatomic, readonly) NSDictionary *root;

// Whether a scene of this size uses the compact variant.
- (BOOL)compactForSize:(CGSize)size;

// Builds the tree into `bounds` (usually the scene minus its safe area).
// `flags` switch "when" variants; `variables` fill "$name" texts; `selected`
// is "<list id>.<item id>" of the highlighted button, drawn in amber.
- (UILayoutResult *)buildIn:(CGRect)bounds sceneSize:(CGSize)size flags:(NSSet<NSString *> *)flags
                  variables:(NSDictionary<NSString *, NSString *> *)variables selected:(NSString *)selected;

// A value from the root's "metrics" object, with "when" variants applied.
- (CGFloat)metric:(NSString *)name flags:(NSSet<NSString *> *)flags fallback:(CGFloat)fallback;
// The root's "items" array (for screens that draw their own rows), filtered
// by an optional per-item "platforms": ["mac", "ios"].
- (NSArray<NSDictionary *> *)items;

@end
