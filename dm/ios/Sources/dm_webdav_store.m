// 通用 HTTPS WebDAV 存档传输：对象按 SHA-256 寻址，索引以强 ETag 做比较交换；双方修改时停下来保留双方。
// Generic HTTPS WebDAV save transport: SHA-256 objects and a strong-ETag compare-and-swap index; preserve both sides on concurrent edits.
#import "dm_webdav_store.h"
#import <CommonCrypto/CommonDigest.h>
#include "dm_cloudpack.h"
#include <stdint.h>
int dm_cloud_sync(const char *, const char *, const char *, const char *, int, uint64_t, int (*)(const char *));
static const NSUInteger limitBytes = 64u << 20;
static NSError *failure(DMWebDAVError code) { return [NSError errorWithDomain:@"D2RWebDAV" code:code userInfo:nil]; }
static BOOL fail(NSError **error, DMWebDAVError code) { if (error) *error = failure(code); return NO; }
static NSString *digest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *out = [NSMutableString string]; for (unsigned i = 0; i < sizeof bytes; i++) [out appendFormat:@"%02x", bytes[i]]; return out;
}
static BOOL unitOK(NSString *name) {
    if (![name isKindOfClass:NSString.class] || !name.length || [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= 64 || [name containsString:@".."] || [name containsString:@"/"] || [name containsString:@"\\"] || [name hasPrefix:@"."]) return NO;
    return [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound && (![name hasPrefix:@"_"] || [name isEqual:@"_stash"]);
}
static BOOL hashOK(id value) { return [value isKindOfClass:NSString.class] && [value length] == 64 && [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound; }
static BOOL strongETag(NSString *tag) { return tag.length >= 2 && [tag hasPrefix:@"\""] && [tag hasSuffix:@"\""] && ![tag containsString:@"\n"] && ![tag containsString:@"\r"]; }
static BOOL equal(id a, id b) { return a == b || [a isEqual:b]; }
static NSDictionary *readJSON(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path]; id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [obj isKindOfClass:NSDictionary.class] ? obj : @{};
}
static BOOL writeJSON(NSDictionary *obj, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:nil]; return data && [data writeToFile:path options:NSDataWritingAtomic error:nil];
}

// 每次同步复用一个有界会话，避免逐请求重做 TLS；拒绝重定向，凭据不会带到其他地址。
// Reuse one bounded session per sync to avoid repeated TLS handshakes; reject redirects so credentials cannot move to another URL.
@interface DMDAVRequest : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) NSMutableData *data;
@property(nonatomic) NSHTTPURLResponse *response;
@property(nonatomic) NSError *error;
@property(nonatomic) dispatch_semaphore_t done;
@property(nonatomic) NSURLSession *session;
@end
@implementation DMDAVRequest
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    (void)session; (void)task; self.response = (NSHTTPURLResponse *)response;
    if (response.expectedContentLength > (int64_t)limitBytes) { self.error = failure(DMWebDAVProtocol); completion(NSURLSessionResponseCancel); } else completion(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session; if (self.data.length + data.length > limitBytes) { self.error = failure(DMWebDAVProtocol); [task cancel]; } else [self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    (void)session; (void)task; (void)response; (void)request; self.error = failure(DMWebDAVProtocol); completion(nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session; (void)task; if (!self.error) self.error = error; dispatch_semaphore_signal(self.done);
}
@end

@interface DMWebDAVStore ()
@property(nonatomic) NSURL *root;
@property(nonatomic) NSString *authorization, *directory;
@property(nonatomic) NSDate *deadline;
@property(nonatomic) DMDAVRequest *http;
@property(nonatomic, readwrite) NSDictionary<NSString *, NSDictionary *> *conflicts;
@end
@implementation DMWebDAVStore
- (instancetype)initWithURL:(NSURL *)url username:(NSString *)user password:(NSString *)password directory:(NSString *)directory {
    if (!(self = [super init])) return nil;
    BOOL secure = [url.scheme.lowercaseString isEqual:@"https"];
#ifdef DM_WEBDAV_TESTING
    secure |= [url.scheme isEqual:@"http"] && ([@[@"127.0.0.1", @"localhost", @"[::1]"] containsObject:url.host]);
#endif
    if (!secure || !url.host.length || url.user || url.password || url.query || url.fragment || !user.length || [user containsString:@":"] || !password.length) return nil;
    self.root = [url URLByAppendingPathComponent:@"d2r-mobile-v1" isDirectory:YES]; self.directory = directory;
    self.authorization = [@"Basic " stringByAppendingString:[[[user stringByAppendingFormat:@":%@", password] dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
    self.conflicts = @{}; return self;
}
- (DMDAVRequest *)request:(NSString *)method path:(NSString *)path data:(NSData *)data condition:(NSString *)header value:(NSString *)value error:(NSError **)error {
    NSTimeInterval left = [self.deadline timeIntervalSinceNow]; if (left <= 0) { fail(error, DMWebDAVNetwork); return nil; }
    NSURL *url = path.length ? [self.root URLByAppendingPathComponent:path] : self.root;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:MIN(left, 5)];
    request.HTTPMethod = method; request.HTTPBody = data; [request setValue:self.authorization forHTTPHeaderField:@"Authorization"];
    if (header) [request setValue:value forHTTPHeaderField:header]; if (data) [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    if (!self.http) {
        self.http = [DMDAVRequest new];
        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration; cfg.URLCache = nil; cfg.HTTPCookieStorage = nil; cfg.URLCredentialStorage = nil; cfg.timeoutIntervalForResource = 5;
        NSOperationQueue *queue = [NSOperationQueue new]; queue.maxConcurrentOperationCount = 1;
        self.http.session = [NSURLSession sessionWithConfiguration:cfg delegate:self.http delegateQueue:queue];
    }
    DMDAVRequest *result = self.http; result.data = [NSMutableData data]; result.response = nil; result.error = nil; result.done = dispatch_semaphore_create(0);
    NSURLSession *session = result.session;
    [[session dataTaskWithRequest:request] resume];
    if (dispatch_semaphore_wait(result.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MIN(left, 5) * NSEC_PER_SEC)))) {
        [session invalidateAndCancel]; fail(error, DMWebDAVNetwork); return nil;
    }
    if (result.error) { fail(error, [result.error.domain isEqual:@"D2RWebDAV"] ? (DMWebDAVError)result.error.code : DMWebDAVNetwork); return nil; }
    if (result.response.statusCode == 401 || result.response.statusCode == 403) { fail(error, DMWebDAVAuth); return nil; }
    DMDAVRequest *completed = [DMDAVRequest new]; completed.data = result.data; completed.response = result.response; return completed;
}
- (BOOL)makeCollection:(NSString *)path error:(NSError **)error {
    DMDAVRequest *r = [self request:@"MKCOL" path:path data:nil condition:nil value:nil error:error]; if (!r) return NO;
    return r.response.statusCode == 201 || r.response.statusCode == 405 ? YES : fail(error, DMWebDAVHTTP);
}
- (BOOL)prepare:(NSError **)error {
    return [NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:error] && [self makeCollection:@"" error:error] && [self makeCollection:@"objects" error:error] && [self makeCollection:@"history" error:error];
}
- (BOOL)probe:(NSError **)error {
    NSString *path = [@"probe-" stringByAppendingString:NSUUID.UUID.UUIDString]; NSData *d = [@"D2R WebDAV conditional write check" dataUsingEncoding:NSUTF8StringEncoding];
    DMDAVRequest *create = [self request:@"PUT" path:path data:d condition:@"If-None-Match" value:@"*" error:error];
    if (!create) return NO; if (create.response.statusCode != 201) return fail(error, DMWebDAVProtocol);
    DMDAVRequest *first = [self request:@"GET" path:path data:nil condition:nil value:nil error:error]; if (!first) return NO;
    NSString *tag = [first.response valueForHTTPHeaderField:@"ETag"];
    if (first.response.statusCode != 200 || !strongETag(tag)) return fail(error, DMWebDAVProtocol);
    NSMutableData *changed = [d mutableCopy]; ((unsigned char *)changed.mutableBytes)[0] ^= 1;
    DMDAVRequest *update = [self request:@"PUT" path:path data:changed condition:@"If-Match" value:tag error:error]; if (!update) return NO;
    DMDAVRequest *second = [self request:@"GET" path:path data:nil condition:nil value:nil error:error]; if (!second) return NO;
    NSString *newTag = [second.response valueForHTTPHeaderField:@"ETag"];
    BOOL changedTag = (update.response.statusCode == 200 || update.response.statusCode == 204) && second.response.statusCode == 200 && [second.data isEqual:changed] && strongETag(newTag) && ![newTag isEqual:tag];
    DMDAVRequest *match = [self request:@"PUT" path:path data:d condition:@"If-Match" value:tag error:error]; if (!match) return NO;
    DMDAVRequest *none = [self request:@"PUT" path:path data:d condition:@"If-None-Match" value:@"*" error:error]; if (!none) return NO;
    BOOL ok = changedTag && match.response.statusCode == 412 && none.response.statusCode == 412;
    [self request:@"DELETE" path:path data:nil condition:nil value:nil error:nil];
    return ok ? YES : fail(error, DMWebDAVProtocol);
}
- (BOOL)checkConnection:(NSError **)error {
    self.deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    @try { return [self prepare:error] && [self probe:error]; }
    @finally { [self.http.session invalidateAndCancel]; self.http = nil; }
}
- (BOOL)resolveUnit:(NSString *)unit useLocal:(BOOL)local error:(NSError **)error {
    NSDictionary *conflict = self.conflicts[unit]; if (!conflict) return fail(error, DMWebDAVConflict);
    NSString *file = [self.directory stringByAppendingPathComponent:@"choices.json"];
    NSMutableDictionary *choices = [readJSON(file) mutableCopy]; NSMutableDictionary *choice = [conflict mutableCopy]; choice[@"useLocal"] = @(local); choices[unit] = choice;
    return writeJSON(choices, file) ? YES : fail(error, DMWebDAVLocal);
}
- (BOOL)syncSave:(NSString *)save allowDownload:(BOOL)download error:(NSError **)error {
    @try { return [self performSync:save allowDownload:download error:error]; }
    @finally { [self.http.session invalidateAndCancel]; self.http = nil; }
}
- (BOOL)performSync:(NSString *)save allowDownload:(BOOL)download error:(NSError **)error {
    self.deadline = [NSDate dateWithTimeIntervalSinceNow:20]; self.conflicts = @{};
    if (![self prepare:error] || ![self probe:error]) return NO;
    DMDAVRequest *head = [self request:@"GET" path:@"index.json" data:nil condition:nil value:nil error:error]; if (!head) return NO;
    NSDictionary *remote = @{}; BOOL absent = head.response.statusCode == 404;
    NSString *etag = [head.response valueForHTTPHeaderField:@"ETag"];
    if (!absent) {
        if (head.response.statusCode != 200 || head.data.length > (256u << 10) || !strongETag(etag)) return fail(error, DMWebDAVProtocol);
        id json = [NSJSONSerialization JSONObjectWithData:head.data options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class] || ![json[@"version"] isEqual:@1] || ![json[@"units"] isKindOfClass:NSDictionary.class]) return fail(error, DMWebDAVProtocol);
        remote = json[@"units"]; if (remote.count > 256) return fail(error, DMWebDAVProtocol);
        for (NSString *unit in remote) if (!unitOK(unit) || !hashOK(remote[unit])) return fail(error, DMWebDAVProtocol);
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *snapshot = [self.directory stringByAppendingPathComponent:@"snapshot"], *export = [self.directory stringByAppendingPathComponent:@"export"];
    if (download && ![fm fileExistsAtPath:save] && ![fm createDirectoryAtPath:save withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSUInteger localBytes = 0;
    for (NSURL *file in [fm enumeratorAtURL:[NSURL fileURLWithPath:save] includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey, NSURLFileSizeKey] options:0 errorHandler:nil]) {
        NSNumber *link = nil, *size = nil; [file getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil]; [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        localBytes += size.unsignedIntegerValue; if (link.boolValue || localBytes > limitBytes) return fail(error, DMWebDAVLocal);
    }
    [fm removeItemAtPath:snapshot error:nil];
    if (![fm copyItemAtPath:save toPath:snapshot error:error] || ![fm createDirectoryAtPath:export withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSString *state = [self.directory stringByAppendingPathComponent:@"export.state"], *backup = [self.directory stringByAppendingPathComponent:@"backups"];
    if (dm_cloud_sync(snapshot.fileSystemRepresentation, export.fileSystemRepresentation, backup.fileSystemRepresentation, state.fileSystemRepresentation, download, (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000), NULL) < 0) return fail(error, DMWebDAVLocal);
    NSMutableDictionary *local = [NSMutableDictionary dictionary]; NSMutableDictionary *paths = [NSMutableDictionary dictionary]; NSUInteger total = 0;
    for (NSString *file in [fm contentsOfDirectoryAtPath:export error:nil]) {
        if (![file hasSuffix:@".pack"]) continue; NSString *unit = file.stringByDeletingPathExtension, *path = [export stringByAppendingPathComponent:file];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!unitOK(unit) || !data || data.length > limitBytes || !dm_cloud_pack_validate(path.fileSystemRepresentation, unit.UTF8String)) return fail(error, DMWebDAVLocal);
        total += data.length; if (total > limitBytes || local.count >= 256) return fail(error, DMWebDAVLocal);
        local[unit] = digest(data); paths[local[unit]] = path;
    }
    NSString *checkpoint = [self.directory stringByAppendingPathComponent:@"checkpoint.json"];
    NSDictionary *base = readJSON(checkpoint), *baseLocal = base[@"local"] ?: @{}, *baseRemote = base[@"remote"] ?: @{};
    if (![baseLocal isKindOfClass:NSDictionary.class] || ![baseRemote isKindOfClass:NSDictionary.class]) return fail(error, DMWebDAVLocal);
    for (NSDictionary *map in @[baseLocal, baseRemote]) for (NSString *unit in map) if (!unitOK(unit) || !hashOK(map[unit])) return fail(error, DMWebDAVLocal);
    NSDictionary *choices = readJSON([self.directory stringByAppendingPathComponent:@"choices.json"]);
    NSMutableSet *names = [NSMutableSet setWithArray:local.allKeys]; [names addObjectsFromArray:remote.allKeys];
    NSMutableDictionary *chosen = [remote mutableCopy], *conflicts = [NSMutableDictionary dictionary]; BOOL needsRestart = NO;
    for (NSString *unit in names) {
        NSString *l = local[unit], *r = remote[unit]; if (equal(l, r)) continue;
        BOOL lc = !equal(l, baseLocal[unit]), rc = !equal(r, baseRemote[unit]);
        BOOL conflict = l && r && lc && rc;
        NSDictionary *choice = [choices[unit] isKindOfClass:NSDictionary.class] ? choices[unit] : nil;
        if (conflict && equal(choice[@"local"], l) && equal(choice[@"remote"], r)) { if ([choice[@"useLocal"] boolValue]) rc = NO; else lc = NO; conflict = NO; }
        if (conflict) { conflicts[unit] = @{@"local":l, @"remote":r}; continue; }
        if (l && (!r || (lc && !rc))) chosen[unit] = l;
        else if (r && !download) needsRestart = YES;
    }
    self.conflicts = conflicts;
    if (chosen.count > 256) return fail(error, DMWebDAVLocal);
    if (conflicts.count) return fail(error, DMWebDAVConflict);
    if (needsRestart) return fail(error, DMWebDAVRestart);
    // 先完整下载、校验所有包，之后才发布索引及替换本地；坏包不能造成部分导入。
    // Download and validate every pack before publishing the index or replacing local data; corrupt packs cannot cause a partial import.
    NSString *incoming = [self.directory stringByAppendingPathComponent:@"incoming"];
    [fm removeItemAtPath:incoming error:nil]; if (![fm createDirectoryAtPath:incoming withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    for (NSString *unit in chosen) {
        NSString *hash = chosen[unit]; if (!paths[hash]) {
            DMDAVRequest *get = [self request:@"GET" path:[@"objects/" stringByAppendingFormat:@"%@.pack", hash] data:nil condition:nil value:nil error:error]; if (!get) return NO;
            total += get.data.length;
            if (get.response.statusCode != 200 || total > limitBytes || ![digest(get.data) isEqual:hash]) return fail(error, DMWebDAVProtocol);
            NSString *path = [incoming stringByAppendingPathComponent:[unit stringByAppendingString:@".pack"]];
            if (![get.data writeToFile:path options:NSDataWritingAtomic error:error] || !dm_cloud_pack_validate(path.fileSystemRepresentation, unit.UTF8String)) return fail(error, DMWebDAVProtocol);
            paths[hash] = path;
        }
    }
    for (NSString *unit in chosen) {
        NSString *hash = chosen[unit]; if (equal(remote[unit], hash)) continue;
        NSData *data = [NSData dataWithContentsOfFile:paths[hash]];
        DMDAVRequest *put = [self request:@"PUT" path:[@"objects/" stringByAppendingFormat:@"%@.pack", hash] data:data condition:@"If-None-Match" value:@"*" error:error]; if (!put) return NO;
        if (put.response.statusCode == 412) {
            DMDAVRequest *get = [self request:@"GET" path:[@"objects/" stringByAppendingFormat:@"%@.pack", hash] data:nil condition:nil value:nil error:error]; if (!get) return NO;
            if (get.response.statusCode != 200 || ![digest(get.data) isEqual:hash]) return fail(error, DMWebDAVProtocol);
        } else if (put.response.statusCode != 201 && put.response.statusCode != 204) return fail(error, DMWebDAVHTTP);
    }
    if (!equal(chosen, remote) || absent) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"units":chosen} options:NSJSONWritingSortedKeys error:nil];
        DMDAVRequest *history = [self request:@"PUT" path:[@"history/" stringByAppendingFormat:@"%@.json", NSUUID.UUID.UUIDString] data:data condition:@"If-None-Match" value:@"*" error:error]; if (!history) return NO;
        if (history.response.statusCode != 201) return fail(error, DMWebDAVHTTP);
        DMDAVRequest *put = [self request:@"PUT" path:@"index.json" data:data condition:absent ? @"If-None-Match" : @"If-Match" value:absent ? @"*" : etag error:error]; if (!put) return NO;
        if (put.response.statusCode == 412) return fail(error, DMWebDAVConflict);
        if (put.response.statusCode != 200 && put.response.statusCode != 201 && put.response.statusCode != 204) return fail(error, DMWebDAVHTTP);
    }
    if (download) for (NSString *unit in chosen) if (dm_cloud_pack_apply(save.fileSystemRepresentation, backup.fileSystemRepresentation, unit.UTF8String, [paths[chosen[unit]] fileSystemRepresentation])) return fail(error, DMWebDAVLocal);
    if (!writeJSON(@{@"local":chosen, @"remote":chosen}, checkpoint)) return fail(error, DMWebDAVLocal);
    [fm removeItemAtPath:snapshot error:nil]; [fm removeItemAtPath:incoming error:nil]; [fm removeItemAtPath:[self.directory stringByAppendingPathComponent:@"choices.json"] error:nil]; return YES;
}
@end
