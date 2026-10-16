// WebDAV 的不可变对象、条件更新与逐单位冲突计划；不读取凭据文件、不触碰界面或运行中的真存档。
// Immutable WebDAV objects, conditional updates and per-unit conflict planning; no credential storage, UI, or live-save access.
#import <Foundation/Foundation.h>
typedef NS_ENUM(NSInteger, DMWebDAVError) {
    DMWebDAVConfig = 1, DMWebDAVNetwork, DMWebDAVAuth, DMWebDAVHTTP, DMWebDAVProtocol,
    DMWebDAVConflict, DMWebDAVRestart, DMWebDAVLocal
};
@interface DMWebDAVStore : NSObject
@property(nonatomic, readonly) NSDictionary<NSString *, NSDictionary *> *conflicts;
- (instancetype)initWithURL:(NSURL *)url username:(NSString *)user password:(NSString *)password directory:(NSString *)directory;
- (BOOL)checkConnection:(NSError **)error;
- (BOOL)syncSave:(NSString *)save allowDownload:(BOOL)download error:(NSError **)error;
- (BOOL)resolveUnit:(NSString *)unit useLocal:(BOOL)local error:(NSError **)error;
@end
