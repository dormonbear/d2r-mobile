// 自动冲突提示的状态；只在主线程访问，与 UIKit 和真实存档分离。
// Automatic conflict prompt state; main-thread only, independent of UIKit and real saves.
#import <Foundation/Foundation.h>
typedef NS_ENUM(NSInteger, DMWebDAVPromptDisposition) {
    DMWebDAVPromptDefer, DMWebDAVPromptWaitForActive, DMWebDAVPromptPresent
};

@interface DMWebDAVConflictPrompts : NSObject
@property(nonatomic, readonly) BOOL hasPending;
+ (BOOL)conflict:(NSDictionary *)conflict matchesVersion:(NSDictionary *)version;
+ (DMWebDAVPromptDisposition)dispositionForPending:(BOOL)pending active:(BOOL)active background:(BOOL)background inGame:(BOOL)inGame;
- (void)updateConflicts:(NSDictionary<NSString *, NSDictionary *> *)conflicts;
- (NSDictionary *)nextConflictWhenEligible:(BOOL)eligible;
- (void)finishConflict:(NSDictionary *)conflict handled:(BOOL)handled;
- (void)deferConflicts;
- (void)resumeConflicts:(NSDictionary<NSString *, NSDictionary *> *)conflicts;
@end
