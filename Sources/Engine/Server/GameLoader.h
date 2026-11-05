#import <Foundation/Foundation.h>
#include "GameAPI.h"

// Finds the game module and returns its GetGameAPI entry point: fs_game (a
// path to a dylib) if set, else Contents/PlugIns/game.dylib in the app.
GetGameAPIFunc GameLoaderOpen(void);
