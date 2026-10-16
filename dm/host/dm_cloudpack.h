// WebDAV 传输层使用的存档包校验与显式导入；沿用同步核心的备份与失败回滚，不按时间猜测赢家。
// Save-pack validation and explicit import for WebDAV; reuse core backups and rollback without choosing a winner by timestamp.
#pragma once
int dm_cloud_pack_validate(const char *pack, const char *unit);
int dm_cloud_pack_apply(const char *save, const char *bak, const char *unit, const char *pack);
// 导出提交快照与删除标记，不合并或选择历史镜像。 | Export a committed snapshot and tombstones without merging historical mirrors.
int dm_cloud_pack_export(const char *save, const char *mirror, unsigned long long now_ms);
