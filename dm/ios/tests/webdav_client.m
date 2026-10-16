// 集成测试驱动：链接真实传输和存档核心，通过真实 HTTP 访问本地协议替身；不含游戏数据。
// Integration driver: link the real transport/save core and access a local protocol stand-in over real HTTP; no game data.
#import "../Sources/dm_webdav_store.h"
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 5) return 2;
        DMWebDAVStore *s = [[DMWebDAVStore alloc] initWithURL:[NSURL URLWithString:@(argv[1])] username:@"user" password:@"pass" directory:@(argv[3])];
        NSError *error = nil; BOOL ok = NO;
        if (s) {
            ok = !strcmp(argv[4], "check") ? [s checkConnection:&error] : [s syncSave:@(argv[2]) allowDownload:atoi(argv[4]) error:&error];
            if (argc >= 7 && s.conflicts[@(argv[5])]) { ok = [s resolveUnit:@(argv[5]) useLocal:atoi(argv[6]) error:&error]; if (ok && argc == 7) ok = [s syncSave:@(argv[2]) allowDownload:atoi(argv[4]) error:&error]; }
        }
        NSDictionary *out = @{@"ok":@(ok), @"code":@(ok ? 0 : error ? error.code : DMWebDAVConfig), @"conflicts":s.conflicts ?: @{}, @"diagnostics":s.diagnostics ?: @{}};
        NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil]; puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
        return 0;
    }
}
