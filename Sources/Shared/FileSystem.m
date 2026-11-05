#import "Shared.h"

static NSString *game;

NSArray<NSString *> *FSGames(void) {
    NSURL *root = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Games" isDirectory:YES];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL]) {
        BOOL directory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&directory] && directory)
            [names addObject:url.lastPathComponent];
    }
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

void FSSetGame(NSString *name) {
    @synchronized (NSBundle.mainBundle) { game = name.length ? [name copy] : nil; }
}

NSString *FSGame(void) {
    @synchronized (NSBundle.mainBundle) {
        if (!game) {
            NSString *preferred = [NSBundle.mainBundle objectForInfoDictionaryKey:@"FSDefaultGame"];
            NSArray<NSString *> *games = FSGames();
            game = [games containsObject:preferred] ? preferred : games.firstObject ?: @"";
        }
        return game;
    }
}

NSDictionary *FSGameManifest(NSString *name) {
    if (!name.length) return @{};
    NSURL *url = [NSBundle.mainBundle URLForResource:@"game" withExtension:@"json"
                                        subdirectory:[@"Games" stringByAppendingPathComponent:name]];
    id json = FSJSON(url);
    return [json isKindOfClass:NSDictionary.class] ? json : @{};
}

NSArray<NSString *> *FSGameChain(void) {
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    for (NSString *name = FSGame(); name.length && ![chain containsObject:name] && chain.count < 8;
         name = FSGameManifest(name)[@"base"]) {
        [chain addObject:name];
    }
    return chain;
}

static NSArray<NSString *> *SearchPath(NSString *subdirectory) {
    NSString *relative = subdirectory.length ? subdirectory : @"";
    NSMutableArray<NSString *> *path = [NSMutableArray array];
    for (NSString *name in FSGameChain())
        [path addObject:[[@"Games" stringByAppendingPathComponent:name] stringByAppendingPathComponent:relative]];
    [path addObject:relative];
    return path;
}

NSURL *FSURL(NSString *subdirectory, NSString *name, NSString *extension) {
    if (!name.length) return nil;
    for (NSString *directory in SearchPath(subdirectory)) {
        NSURL *url = [NSBundle.mainBundle URLForResource:name withExtension:extension subdirectory:directory];
        if (url) return url;
    }
    return nil;
}

NSArray<NSURL *> *FSURLs(NSString *subdirectory, NSString *extension) {
    NSMutableDictionary<NSString *, NSURL *> *found = [NSMutableDictionary dictionary];
    for (NSString *directory in SearchPath(subdirectory)) {
        for (NSURL *url in [NSBundle.mainBundle URLsForResourcesWithExtension:extension subdirectory:directory]) {
            NSString *key = url.lastPathComponent;
            if (!found[key]) found[key] = url;
        }
    }
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *name in [found.allKeys sortedArrayUsingSelector:@selector(compare:)]) [urls addObject:found[name]];
    return urls;
}

NSArray<NSURL *> *FSURLsLayered(NSString *subdirectory, NSString *extension) {
    NSMutableArray<NSURL *> *found = [NSMutableArray array];
    for (NSString *directory in SearchPath(subdirectory).reverseObjectEnumerator) {
        NSArray *urls = [NSBundle.mainBundle URLsForResourcesWithExtension:extension subdirectory:directory];
        [found addObjectsFromArray:[urls sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent compare:b.lastPathComponent];
        }]];
    }
    return found;
}

id FSJSON(NSURL *url) {
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    if (!data) return nil;
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!json) NSLog(@"FileSystem: cannot read %@: %@", url.lastPathComponent, error.localizedDescription);
    return json;
}
