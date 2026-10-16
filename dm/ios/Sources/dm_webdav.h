// iOS 的 WebDAV 设置与生命周期接线；启用后独占存档同步，避免两个后端同时上传。
// iOS WebDAV settings and lifecycle wiring; when enabled it owns save sync so two backends cannot upload simultaneously.
#pragma once
int dm_webdav_boot(const char *save);
int dm_webdav_active(void);
void dm_webdav_flush(int background);
int dm_webdav_flush_wait(double seconds);
void dm_webdav_foreground(void);
void dm_webdav_present(void);
