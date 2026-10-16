// 飞牛及通用 WebDAV：凭据留在本机钥匙串，串行队列上传提交快照，启动前才允许导入。
// fnOS and generic WebDAV: credentials stay in the device Keychain; a serial queue uploads committed snapshots and imports only before game startup.
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import "dm_webdav.h"
#import "dm_webdav_store.h"
#include <sys/clonefile.h>
#include <stdatomic.h>
const char *dm_ui(const char *key);
void plog(const char *format, ...);
static NSString *T(const char *key) { return @(dm_ui(key)); }
static NSString *const configKey = @"D2RWebDAVConfig";
static DMWebDAVStore *store;
static NSDictionary *bootConfig;
static NSString *pending, *work;
static _Atomic int ownsSync, inRun, inBackground;
static NSInteger status;
static NSString *lastSuccess;
static NSArray<NSString *> *conflictUnits;
static NSObject *guard;
static dispatch_queue_t queue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("dm.webdav", DISPATCH_QUEUE_SERIAL); guard = [NSObject new]; conflictUnits = @[]; }); return q;
}
static NSDictionary *config(void) { id c = [NSUserDefaults.standardUserDefaults objectForKey:configKey]; return [c isKindOfClass:NSDictionary.class] ? c : @{}; }
static NSString *account(NSDictionary *c) { return [NSString stringWithFormat:@"%@\n%@", c[@"url"] ?: @"", c[@"user"] ?: @""]; }
static NSMutableDictionary *keyQuery(NSDictionary *c) { return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService:@"org.d2rmobile.webdav", (__bridge id)kSecAttrAccount:account(c)} mutableCopy]; }
static NSString *password(NSDictionary *c) {
    NSMutableDictionary *q = keyQuery(c); q[(__bridge id)kSecReturnData] = @YES; q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef value = NULL; OSStatus result = SecItemCopyMatching((__bridge CFDictionaryRef)q, &value);
    NSData *data = CFBridgingRelease(value); return result == errSecSuccess ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}
static BOOL savePassword(NSDictionary *c, NSString *value) {
    NSMutableDictionary *q = keyQuery(c); NSDictionary *attrs = @{(__bridge id)kSecValueData:[value dataUsingEncoding:NSUTF8StringEncoding], (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus result = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)attrs);
    if (result == errSecItemNotFound) { [q addEntriesFromDictionary:attrs]; result = SecItemAdd((__bridge CFDictionaryRef)q, NULL); } return result == errSecSuccess;
}
static NSString *workingDirectory(NSDictionary *c) {
    NSData *identity = [account(c) dataUsingEncoding:NSUTF8StringEncoding]; unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(identity.bytes, (CC_LONG)identity.length, hash);
    NSMutableString *name = [NSMutableString string]; for (unsigned i = 0; i < sizeof hash; i++) [name appendFormat:@"%02x", hash[i]];
    NSString *root = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[root stringByAppendingPathComponent:@"webdav"] stringByAppendingPathComponent:name];
}
static DMWebDAVStore *makeStore(NSDictionary *c, NSString *secret) { return [[DMWebDAVStore alloc] initWithURL:[NSURL URLWithString:c[@"url"] ?: @""] username:c[@"user"] ?: @"" password:secret ?: @"" directory:workingDirectory(c)]; }
static void result(BOOL ok, NSError *error) {
    @synchronized(guard) { status = ok ? 0 : ([error.domain isEqual:@"D2RWebDAV"] ? error.code : DMWebDAVLocal); conflictUnits = [store.conflicts.allKeys sortedArrayUsingSelector:@selector(compare:)];
        if (ok) { lastSuccess = [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
            NSMutableDictionary *dates = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"D2RWebDAVSuccessDates"] mutableCopy] ?: [NSMutableDictionary dictionary];
            dates[account(bootConfig)] = lastSuccess; [NSUserDefaults.standardUserDefaults setObject:dates forKey:@"D2RWebDAVSuccessDates"]; } }
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:@"D2RWebDAVStatus" object:nil]; });
    plog("WebDAV sync: %s (status %ld)", ok ? "complete" : "pending", (long)status);
}
static BOOL unchangedConfig(void) { NSDictionary *c = config(); return [c[@"enabled"] boolValue] && [c isEqual:bootConfig]; }
static void upload(void) {
    if (!pending || !unchangedConfig()) return;
    NSError *error = nil; BOOL ok = [store syncSave:pending allowDownload:NO error:&error]; result(ok, error);
    if (ok) { [NSFileManager.defaultManager removeItemAtPath:pending error:nil]; pending = nil; }
}
static void committed(const char *save) {
    if (!unchangedConfig()) return;
    NSString *snap = [work stringByAppendingPathComponent:[@"pending-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (clonefile(save, snap.fileSystemRepresentation, 0)) { dispatch_async(queue(), ^{ result(NO, [NSError errorWithDomain:@"D2RWebDAV" code:DMWebDAVLocal userInfo:nil]); }); return; }
    int defer = atomic_load(&inRun) && !atomic_load(&inBackground);
    dispatch_async(queue(), ^{ if (pending) [NSFileManager.defaultManager removeItemAtPath:pending error:nil]; pending = snap; if (!defer) upload(); });
}
static void entered(int on) { if (on) atomic_store(&inRun, 1); }
static void left(void) { if (atomic_exchange(&inRun, 0)) dm_webdav_flush(0); }
int dm_webdav_boot(const char *save) {
    queue(); NSDictionary *c = config(); if (![c[@"enabled"] boolValue]) return 0;
    atomic_store(&ownsSync, 1); bootConfig = [c copy]; work = workingDirectory(c); store = makeStore(c, password(c));
    dispatch_sync(queue(), ^{ if (store) { NSError *error = nil; BOOL ok = [store syncSave:@(save) allowDownload:YES error:&error]; result(ok, error); }
        else result(NO, [NSError errorWithDomain:@"D2RWebDAV" code:DMWebDAVConfig userInfo:nil]); });
    extern void (*g_dm_save_commit_hook)(const char *); extern void (*g_dm_ingame_hook)(int); extern void (*g_dm_charsel_hook)(void);
    g_dm_save_commit_hook = committed; g_dm_ingame_hook = entered; g_dm_charsel_hook = left; return 1;
}
int dm_webdav_active(void) { return atomic_load(&ownsSync); }
void dm_webdav_foreground(void) { atomic_store(&inBackground, 0); }
void dm_webdav_flush(int background) {
    if (background) atomic_store(&inBackground, 1);
    __block UIBackgroundTaskIdentifier token = UIBackgroundTaskInvalid;
    if (background) token = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"WebDAV save upload" expirationHandler:^{
        if (token != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:token]; token = UIBackgroundTaskInvalid; }
    }];
    dispatch_async(queue(), ^{ upload(); dispatch_async(dispatch_get_main_queue(), ^{ if (token != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:token]; token = UIBackgroundTaskInvalid; } }); });
}
int dm_webdav_flush_wait(double seconds) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0); dispatch_async(queue(), ^{ upload(); dispatch_semaphore_signal(done); });
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;
}

// 设置页只保存连接信息；切换后端或服务器后必须重启，避免在局内导入或连接到旧服务器。
// Settings save connection details only; changing backend/server requires a restart to avoid in-run imports or connecting to the old server.
@interface DMDAVSettings : UITableViewController
@property(nonatomic) NSArray<UITextField *> *fields;
@property(nonatomic) UISwitch *enabled;
@end
@implementation DMDAVSettings
- (void)viewDidLoad {
    [super viewDidLoad]; queue(); self.title = T("dmDAVTitle");
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 60;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    NSDictionary *c = config(); NSMutableArray<UITextField *> *fields = [NSMutableArray array];
    const char *keys[] = {"dmDAVURL", "dmDAVUser", "dmDAVPassword"};
    for (int i = 0; i < 3; i++) { UITextField *f = [UITextField new]; f.placeholder = T(keys[i]); f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.autocorrectionType = UITextAutocorrectionTypeNo; f.clearButtonMode = UITextFieldViewModeWhileEditing;
        if (i == 0) f.keyboardType = UIKeyboardTypeURL; if (i == 2) { f.secureTextEntry = YES; f.textContentType = UITextContentTypePassword; } [fields addObject:f]; }
    self.fields = fields; fields[0].text = c[@"url"]; fields[1].text = c[@"user"]; fields[2].text = password(c);
    self.enabled = [UISwitch new]; self.enabled.on = [c[@"enabled"] boolValue];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:@"D2RWebDAVStatus" object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)done { [self.view endEditing:YES]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)refresh { [self.tableView reloadData]; }
- (void)message:(const char *)key {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:T("dmDAVTitle") message:T(key) preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:T("dmDAVOK") style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; if (section == 0) return 1; if (section == 1 || section == 2) return 3; @synchronized(guard) { return 1 + (NSInteger)conflictUnits.count; } }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; return section == 1 ? T("dmDAVHint") : section == 2 ? T("dmDAVTiming") : nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView; UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]; cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    if (path.section == 0) { cell.textLabel.text = T("dmDAVEnable"); cell.accessoryView = self.enabled; }
    else if (path.section == 1) { UITextField *field = self.fields[path.row]; field.translatesAutoresizingMaskIntoConstraints = NO; [cell.contentView addSubview:field];
        [NSLayoutConstraint activateConstraints:@[[field.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16], [field.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16], [field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8], [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8], [field.heightAnchor constraintGreaterThanOrEqualToConstant:30]]]; cell.selectionStyle = UITableViewCellSelectionStyleNone; }
    else if (path.section == 2) { const char *keys[] = {"dmDAVSave", "dmDAVTest", "dmDAVUpload"}; cell.textLabel.text = T(keys[path.row]); cell.textLabel.textColor = self.view.tintColor; }
    else { @synchronized(guard) { if (path.row && (NSUInteger)path.row <= conflictUnits.count) { cell.textLabel.text = conflictUnits[path.row - 1]; cell.detailTextLabel.text = T("dmDAVConflict"); cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
        else { const char *keys[] = {"dmDAVReady", "dmDAVBadConfig", "dmDAVOffline", "dmDAVAuth", "dmDAVHTTP", "dmDAVProtocol", "dmDAVConflict", "dmDAVRestart", "dmDAVLocal"}; NSInteger s = MIN(MAX(status, 0), 8);
            NSDictionary *c = config(); NSString *last = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"D2RWebDAVSuccessDates"][account(c)];
            cell.textLabel.text = T(![c[@"enabled"] boolValue] ? "dmDAVDisabled" : !unchangedConfig() ? "dmDAVRestart" : keys[s]);
            cell.detailTextLabel.text = last ? [NSString stringWithFormat:T("dmDAVLast"), last] : T("dmDAVNever"); } } }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; [self.view endEditing:YES];
    if (path.section == 2 && path.row == 0) {
        NSDictionary *c = @{@"enabled":@(self.enabled.on), @"url":[self.fields[0].text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet], @"user":self.fields[1].text ?: @"", @"revision":NSUUID.UUID.UUIDString};
        if (self.enabled.on && !makeStore(c, self.fields[2].text)) { [self message:"dmDAVBadConfig"]; return; }
        if (self.enabled.on && !savePassword(c, self.fields[2].text)) { [self message:"dmDAVLocal"]; return; }
        [NSUserDefaults.standardUserDefaults setObject:c forKey:configKey]; [self message:"dmDAVSaved"]; return;
    }
    if (path.section == 2 && path.row == 1) {
        NSDictionary *c = @{@"url":self.fields[0].text ?: @"", @"user":self.fields[1].text ?: @""}; NSString *secret = self.fields[2].text;
        dispatch_async(queue(), ^{ DMWebDAVStore *test = makeStore(c, secret); NSError *error = nil; BOOL ok = test && [test checkConnection:&error];
            dispatch_async(dispatch_get_main_queue(), ^{ [self message:ok ? "dmDAVConnected" : "dmDAVConnectFailed"]; }); }); return;
    }
    if (path.section == 2 && path.row == 2) {
        if (!dm_webdav_active() || !unchangedConfig()) { [self message:"dmDAVRestart"]; return; }
        dispatch_async(queue(), ^{ if (pending) upload(); else result(NO, [NSError errorWithDomain:@"D2RWebDAV" code:DMWebDAVRestart userInfo:nil]); }); return;
    }
    if (path.section == 3 && path.row) {
        __block NSString *unit; @synchronized(guard) { if ((NSUInteger)path.row <= conflictUnits.count) unit = conflictUnits[path.row - 1]; } if (!unit) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:unit message:T("dmDAVChooseHint") preferredStyle:UIAlertControllerStyleAlert];
        for (int local = 0; local <= 1; local++) [a addAction:[UIAlertAction actionWithTitle:T(local ? "dmDAVUseLocal" : "dmDAVUseRemote") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action;
            dispatch_async(queue(), ^{ NSError *error = nil; BOOL ok = [store resolveUnit:unit useLocal:local error:&error]; dispatch_async(dispatch_get_main_queue(), ^{ [self message:ok ? "dmDAVChoiceSaved" : "dmDAVConflict"]; }); }); }]];
        [a addAction:[UIAlertAction actionWithTitle:T("dmDAVCancel") style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:a animated:YES completion:nil];
    }
}
@end
void dm_webdav_present(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ UIViewController *vc = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive)
            for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) vc = window.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController; if (!vc) return;
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[[DMDAVSettings alloc] initWithStyle:UITableViewStyleInsetGrouped]];
        navigation.modalPresentationStyle = UIModalPresentationFormSheet; [vc presentViewController:navigation animated:YES completion:nil];
    });
}
