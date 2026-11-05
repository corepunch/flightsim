#import "GameLoader.h"
#import "Cvar.h"
#import "FileSystem.h"
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#include <dlfcn.h>
#endif

NSString *GameLoaderSelectGame(void) {
    NSString *name = [Cvar get:@"fs_game" defaultValue:FSGame() flags:CVAR_NOSET
                          help:@"Game to run: a folder in the app's Games/"].string;
    if (![FSGames() containsObject:name]) {
        NSLog(@"GameLoader: no game named %@; running %@", name, FSGame());
        name = FSGame();
        [Cvar setInitializing:YES];   // a correction, not a console change
        [Cvar set:@"fs_game" value:name];
        [Cvar setInitializing:NO];
    }
    FSSetGame(name);
    return name;
}

GetGameAPIFunc GameLoaderOpen(void) {
#if TARGET_OS_IOS
    return GetGameAPI;
#else
    // The game's own module, else its base's (FileSystem.h).
    NSString *path = nil;
    for (NSString *game in FSGameChain()) {
        path = [NSBundle.mainBundle.builtInPlugInsPath stringByAppendingPathComponent:[game stringByAppendingPathExtension:@"dylib"]];
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) break;
    }
    if (!path) {
        NSLog(@"GameLoader: no game to load");
        return NULL;
    }
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        NSLog(@"GameLoader: cannot load %@: %s", path, dlerror());
        return NULL;
    }
    GetGameAPIFunc entry = (GetGameAPIFunc)dlsym(handle, "GetGameAPI");
    if (!entry) NSLog(@"GameLoader: %@ has no GetGameAPI", path);
    else NSLog(@"GameLoader: loaded %@", path);
    // Never dlclose: an image with Objective-C classes can't be unloaded.
    return entry;
#endif
}
