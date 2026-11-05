#import "GameLoader.h"
#import "Cvar.h"
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#include <dlfcn.h>
#endif

GetGameAPIFunc GameLoaderOpen(void) {
#if TARGET_OS_IOS
    return GetGameAPI;
#else
    // fs_game names the module to load. Today that is a path to a dylib; the
    // Games/<name> folder layout will make it a game name.
    NSString *override = [Cvar get:@"fs_game" defaultValue:@"" flags:CVAR_NOSET
                               help:@"Game module to load (path to a dylib; default: the app's game.dylib)"].string;
    NSString *path = override.length ? override
                                     : [[NSBundle mainBundle].builtInPlugInsPath stringByAppendingPathComponent:@"game.dylib"];
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
