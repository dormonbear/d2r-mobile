#pragma once

// Run only at character selection, on the guest main thread. The worker receives
// an isolated save copy; failure leaves the mounted and committed saves intact.
typedef int (*dm_save_sync_worker)(const char *save, void *context);
typedef void (*dm_save_sync_done)(int error, void *context);
int dm_save_reload_request(dm_save_sync_worker worker, dm_save_sync_done done, void *context);
int dm_fs_sync_save(dm_save_sync_worker worker, void *context);
