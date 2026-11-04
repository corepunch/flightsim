#import <Foundation/Foundation.h>

// Offline effect preview: renders one effect on a black background with the
// game camera's HDR + bloom settings at a fixed 60 fps timestep and encodes
// it to H.264 .mp4 (plus a contact-sheet .png of 12 frames next to it).
//
//   SpaceFight --record-fx explosion out.mp4 [seconds]
//   effects: explosion, impact, shield, bolt, exhaust, all
@interface FXRecorder : NSObject

+ (int)recordEffect:(NSString *)effect toFile:(NSString *)path seconds:(double)seconds;

@end
