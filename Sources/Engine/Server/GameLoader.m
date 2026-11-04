#import "GameLoader.h"
#include <dlfcn.h>

GetGameAPIFunc GameLoaderOpen(void) {
    const char *override = getenv("SF_GAME");
    NSString *path = override ? @(override)
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
}
