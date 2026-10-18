#import "dm_webdav_conflicts.h"
#include <assert.h>

static NSDictionary *versions(NSString *local) { return @{@"local":local, @"remote":@"server"}; }
int main(void) { @autoreleasepool {
    assert([DMWebDAVConflictPrompts dispositionForPending:YES active:NO background:NO inGame:NO] == DMWebDAVPromptWaitForActive);
    assert([DMWebDAVConflictPrompts dispositionForPending:YES active:YES background:NO inGame:NO] == DMWebDAVPromptPresent);
    assert([DMWebDAVConflictPrompts dispositionForPending:YES active:NO background:YES inGame:NO] == DMWebDAVPromptDefer);
    assert([DMWebDAVConflictPrompts dispositionForPending:YES active:YES background:NO inGame:YES] == DMWebDAVPromptDefer);
    assert([DMWebDAVConflictPrompts dispositionForPending:NO active:YES background:NO inGame:NO] == DMWebDAVPromptDefer);
    DMWebDAVConflictPrompts *p = [DMWebDAVConflictPrompts new];
    assert(!p.hasPending && ![p nextConflictWhenEligible:YES]);
    [p updateConflicts:@{@"dormon":versions(@"ipad"), @"_stash":versions(@"stash")}];
    assert(p.hasPending && ![p nextConflictWhenEligible:NO]); // background / in-game gate
    NSDictionary *stash = [p nextConflictWhenEligible:YES];
    assert([stash[@"unit"] isEqual:@"_stash"]);
    assert(![p nextConflictWhenEligible:YES]); // only one modal at a time
    [p finishConflict:stash handled:YES];
    NSDictionary *character = [p nextConflictWhenEligible:YES];
    assert([character[@"unit"] isEqual:@"dormon"]);
    assert([DMWebDAVConflictPrompts conflict:character matchesVersion:versions(@"ipad")]);
    assert(![DMWebDAVConflictPrompts conflict:character matchesVersion:versions(@"new ipad")]);
    assert(![DMWebDAVConflictPrompts conflict:character matchesVersion:@{}]);
    [p finishConflict:character handled:YES];
    [p updateConflicts:@{@"dormon":versions(@"ipad"), @"_stash":versions(@"stash")}];
    assert(!p.hasPending && ![p nextConflictWhenEligible:YES]); // repeated sync does not nag
    [p updateConflicts:@{@"dormon":versions(@"new ipad")}];
    NSDictionary *changed = [p nextConflictWhenEligible:YES];
    assert(changed && ![changed isEqual:character]); // changed content asks again
    [p finishConflict:character handled:YES];
    assert(![p nextConflictWhenEligible:YES]); // stale completion cannot release a newer modal
    [p finishConflict:changed handled:NO];
    assert([[p nextConflictWhenEligible:YES] isEqual:changed]); // failed choices remain actionable
    [p finishConflict:changed handled:YES];
    [p updateConflicts:@{@"dormon":versions(@"third"), @"_stash":versions(@"other stash")}];
    assert([p nextConflictWhenEligible:YES]);
    [p deferConflicts];
    assert(!p.hasPending && ![p nextConflictWhenEligible:YES]); // Later defers the whole batch
    [p updateConflicts:@{@"dormon":versions(@"third"), @"_stash":versions(@"other stash")}];
    assert(!p.hasPending); // a failed sync republishes the last verified snapshot without nagging
    [p resumeConflicts:@{@"dormon":versions(@"third")}];
    NSDictionary *resumed = [p nextConflictWhenEligible:YES];
    assert([resumed[@"unit"] isEqual:@"dormon"]); // manual choice resumes the undecided batch
    [p finishConflict:resumed handled:YES];
    assert(!p.hasPending); // already decided/deferred stash is not reopened
    [p updateConflicts:@{@"dormon":versions(@"fourth"), @"_stash":versions(@"other stash")}];
    assert([[p nextConflictWhenEligible:YES][@"unit"] isEqual:@"dormon"]);
    [p updateConflicts:@{}];
    [p deferConflicts];
    assert(!p.hasPending);
    puts("WebDAV conflict prompt lifecycle passed");
} return 0; }
