// WebDAV 的不可变对象、条件更新与逐单位冲突计划；不读取凭据文件、不触碰界面或运行中的真存档。
// Immutable WebDAV objects, conditional updates and per-unit conflict planning; no credential storage, UI, or live-save access.
#import <Foundation/Foundation.h>
typedef NS_ENUM(NSInteger, DMWebDAVError) {
    DMWebDAVConfig = 1, DMWebDAVNetwork, DMWebDAVAuth, DMWebDAVHTTP, DMWebDAVProtocol,
    DMWebDAVConflict, DMWebDAVRestart, DMWebDAVLocal
};
typedef NS_ENUM(NSInteger, DMWebDAVPhase) {
    DMWebDAVPreparing, DMWebDAVChecking, DMWebDAVDownloading,
    DMWebDAVUploading, DMWebDAVApplying
};
@interface DMWebDAVStore : NSObject
@property(nonatomic, copy) void (^progress)(DMWebDAVPhase phase);
@property(nonatomic, readonly) NSDictionary<NSString *, NSDictionary *> *conflicts;
// 诊断只含请求方法、相对路径和状态，不含地址、用户名、凭据或响应正文。
// Diagnostics contain only method, relative path and status, never address, username, credentials or response body.
@property(nonatomic, readonly) NSDictionary *diagnostics;
- (instancetype)initWithURL:(NSURL *)url username:(NSString *)user password:(NSString *)password directory:(NSString *)directory;
- (BOOL)checkConnection:(NSError **)error;
- (BOOL)syncSave:(NSString *)save allowDownload:(BOOL)download error:(NSError **)error;
- (BOOL)resolveUnit:(NSString *)unit useLocal:(BOOL)local error:(NSError **)error;
- (BOOL)choicesReady;
- (NSDictionary<NSString *, NSDictionary *> *)unresolvedChoices;
// Keep checkpoints, choices and pack mirrors provisional until the host has
// installed both save directories. Failed installs must remain safely retryable.
- (BOOL)beginReload:(NSError **)error;
- (BOOL)finishReload:(BOOL)installed error:(NSError **)error;
@end
