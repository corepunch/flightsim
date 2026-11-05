#import <Foundation/Foundation.h>
#include "GameAPI.h"

// Picks the game and finds its module.
//
// fs_game names a folder in the bundle's Games/ (default: the Info.plist's
// FSDefaultGame, else the first folder). GameLoaderSelectGame registers the
// cvar and points the file system at that folder; call it once at boot,
// after the command line's +set. GameLoaderOpen returns the game's
// GetGameAPI: on macOS from Contents/PlugIns/<game>.dylib (or its base's,
// for a game with no module of its own), on iOS the one module linked into the app.
NSString *GameLoaderSelectGame(void);
GetGameAPIFunc GameLoaderOpen(void);
