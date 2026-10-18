#import "dm_webdav_conflicts.h"

@interface DMWebDAVConflictPrompts ()
@property(nonatomic) NSDictionary<NSString *, NSDictionary *> *conflicts;
@property(nonatomic) NSMutableSet<NSArray *> *handled;
@property(nonatomic) NSDictionary *active;
@end
@implementation DMWebDAVConflictPrompts
+ (DMWebDAVPromptDisposition)dispositionForPending:(BOOL)pending active:(BOOL)active background:(BOOL)background inGame:(BOOL)inGame {
    if (!pending || background || inGame) return DMWebDAVPromptDefer;
    return active ? DMWebDAVPromptPresent : DMWebDAVPromptWaitForActive;
}
+ (BOOL)conflict:(NSDictionary *)conflict matchesVersion:(NSDictionary *)version {
    return [conflict[@"local"] isEqual:version[@"local"]] && [conflict[@"remote"] isEqual:version[@"remote"]];
}
- (instancetype)init {
    if ((self = [super init])) { _conflicts = @{}; _handled = [NSMutableSet set]; }
    return self;
}
- (NSArray *)identity:(NSDictionary *)item { return @[item[@"unit"], item[@"local"], item[@"remote"]]; }
- (NSDictionary *)item:(NSString *)unit {
    NSDictionary *version = self.conflicts[unit];
    return @{@"unit":unit, @"local":version[@"local"], @"remote":version[@"remote"]};
}
- (void)updateConflicts:(NSDictionary<NSString *, NSDictionary *> *)conflicts {
    self.conflicts = [conflicts copy];
    // 只记当前版本，长期游玩不会无限积累提示记录。
    // Retain only current versions so a long session cannot grow prompt history without bound.
    NSMutableSet *current = [NSMutableSet set];
    for (NSString *unit in self.conflicts) [current addObject:[self identity:[self item:unit]]];
    if (self.active) [current addObject:[self identity:self.active]];
    [self.handled intersectSet:current];
}
- (BOOL)hasPending {
    for (NSString *unit in self.conflicts) if (![self.handled containsObject:[self identity:[self item:unit]]]) return YES;
    return NO;
}
- (NSDictionary *)nextConflictWhenEligible:(BOOL)eligible {
    if (!eligible || self.active) return nil;
    for (NSString *unit in [self.conflicts.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *item = [self item:unit];
        if (![self.handled containsObject:[self identity:item]]) { self.active = item; return item; }
    }
    return nil;
}
- (void)finishConflict:(NSDictionary *)conflict handled:(BOOL)handled {
    if (handled) [self.handled addObject:[self identity:conflict]];
    if ([self.active isEqual:conflict]) self.active = nil;
}
- (void)deferConflicts {
    for (NSString *unit in self.conflicts) [self.handled addObject:[self identity:[self item:unit]]];
    self.active = nil;
}
- (void)resumeConflicts:(NSDictionary<NSString *, NSDictionary *> *)conflicts {
    for (NSString *unit in conflicts) {
        NSDictionary *version = conflicts[unit];
        [self.handled removeObject:@[unit, version[@"local"], version[@"remote"]]];
    }
}
@end
