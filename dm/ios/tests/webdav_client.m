// 集成测试驱动：链接真实传输和存档核心，通过真实 HTTP 访问本地协议替身；不含游戏数据。
// Integration driver: link the real transport/save core and access a local protocol stand-in over real HTTP; no game data.
#import "../Sources/dm_webdav_store.h"
#include <sys/clonefile.h>
#include <stdio.h>
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 5) return 2;
        DMWebDAVStore *s = [[DMWebDAVStore alloc] initWithURL:[NSURL URLWithString:@(argv[1])] username:@"user" password:@"pass" directory:@(argv[3])];
        NSError *error = nil; BOOL ok = NO;
        NSMutableArray *phases = [NSMutableArray array];
        s.progress = ^(DMWebDAVPhase phase) { [phases addObject:@(phase)]; };
        NSNumber *readyAfterChoice = @NO;
        BOOL reloadOnly = !strcmp(argv[4], "reload-only");
        BOOL reload = reloadOnly || !strcmp(argv[4], "abort-reload") || !strcmp(argv[4], "install-reload");
        NSDictionary *retained = nil;
        if (s) {
            ok = reloadOnly ? YES : !strcmp(argv[4], "check") ? [s checkConnection:&error] : [s syncSave:@(argv[2]) allowDownload:atoi(argv[4]) error:&error];
            if (argc >= 7 && s.conflicts[@(argv[5])]) { ok = [s resolveUnit:@(argv[5]) useLocal:atoi(argv[6]) error:&error]; readyAfterChoice = @([s choicesReady]); if (ok && argc == 7 && !reload) ok = [s syncSave:@(argv[2]) allowDownload:atoi(argv[4]) error:&error]; }
            if (reload && ok) {
                NSString *copy = [@(argv[2]) stringByAppendingString:@".reload-copy"];
                if (clonefile(argv[2], copy.fileSystemRepresentation, 0)) return 5;
                ok = [s beginReload:&error] && [s syncSave:copy allowDownload:YES error:&error];
                BOOL installed = ok && strcmp(argv[4], "abort-reload");
                if (installed && renamex_np(copy.fileSystemRepresentation, argv[2], RENAME_SWAP)) return 7;
                if (![s finishReload:installed error:&error]) return 6;
                [NSFileManager.defaultManager removeItemAtPath:copy error:nil];
            }
            if (!strcmp(argv[4], "failure-retains-conflicts") && s.conflicts.count) {
                NSString *save = @(argv[2]), *moved = [save stringByAppendingString:@".temporarily-missing"];
                if (![NSFileManager.defaultManager moveItemAtPath:save toPath:moved error:nil]) return 3;
                ok = [s syncSave:save allowDownload:NO error:&error]; retained = s.conflicts;
                if (![NSFileManager.defaultManager moveItemAtPath:moved toPath:save error:nil]) return 4;
            }
        }
        NSDictionary *out = @{@"ok":@(ok), @"code":@(ok ? 0 : error ? error.code : DMWebDAVConfig), @"conflicts":s.conflicts ?: @{}, @"retainedConflicts":retained ?: @{}, @"diagnostics":s.diagnostics ?: @{}, @"phases":phases, @"choicesReady":@([s choicesReady]), @"readyAfterChoice":readyAfterChoice};
        NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil]; puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
        return 0;
    }
}
