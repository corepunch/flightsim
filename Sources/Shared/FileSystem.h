#import <Foundation/Foundation.h>

// Quake's search path for this engine. The bundle's resources hold the
// engine's own files (fonts, shaders, strings, UI theme) at the top level and
// one folder per game under Games/<name>/. A lookup tries the game folder
// first, then the top level, so a game ships only what it adds or overrides:
//
//   FSURL(@"Data/Ships", @"executioner", @"json")
//     → Games/<game>/Data/Ships/executioner.json, else Data/Ships/executioner.json
//
// A game may build on another, as a Quake mod builds on baseq2: its
// Games/<name>/game.json names a "base", searched after the game's own folder
// and before the top level. A game with no module of its own runs its base's.
//
//   game.json  { "title": "…", "base": "<game>" }
//
// The game is fs_game. The engine sets it at boot; the game module, which has
// its own copy of this file, sets it from the cvar in its init. Until then it
// is the bundle's FSDefaultGame Info.plist key, else the first folder in Games/.
// Thread-safe.

void FSSetGame(NSString *name);
NSString *FSGame(void);
// Every game folder in the bundle, sorted.
NSArray<NSString *> *FSGames(void);
// Games/<name>/game.json, or an empty dictionary.
NSDictionary *FSGameManifest(NSString *name);
// The game, then its base, then the base's base: the folders searched, in order.
NSArray<NSString *> *FSGameChain(void);

// The first match on the search path, or nil.
NSURL *FSURL(NSString *subdirectory, NSString *name, NSString *extension);
// Every file with `extension` in `subdirectory` on the search path. A game
// file hides a top-level file of the same name. Sorted by name.
NSArray<NSURL *> *FSURLs(NSString *subdirectory, NSString *extension);
// Every file with `extension` in `subdirectory`, top level first, then the
// game's: for catalogs a game extends rather than replaces.
NSArray<NSURL *> *FSURLsLayered(NSString *subdirectory, NSString *extension);
// The JSON object in a file, or nil (logged when the file exists but does not parse).
id FSJSON(NSURL *url);
