# Phase 9.5 — ReadingAnchor 接入

> 前置阅读：`00-overview.md`、`05-phase9.4-reader-integration.md`（须已完成）

## 目标

保持 Phase 1 已有的 `ReadingAnchor` 语义不变，验证其可以完整对接新的
lazy 数据流。

## 恢复流程

```
ReadingAnchor
 ↓
chapterId
 ↓
VirtualChapter
 ↓
chunk offset
 ↓
load chunk
 ↓
paragraphHash correction
 ↓
charOffset correction
 ↓
paginate
```

**禁止**重新依赖 `pageIndex` 作为唯一恢复依据（pageIndex 在动态分页
系统下不稳定，这是 Phase 1 已确认的既有约束，本阶段不得回退）。

## 验证要点

- `paragraphHash correction` 在新数据流下是否仍然有效：抽取若干个
  已知位置的段落，在 lazy 模式下重新计算 hash，与旧全量模式下的结果
  比对，必须一致。
- `charOffset` 的语义（byte / character / UTF-16 code unit）必须与
  Phase 9.1 审计中确认的定义完全一致，不允许在这一层引入新的转换歧义。
- 冷启动恢复（App 完全重启后）与热启动恢复（Reader Session 仍在内存中）
  都要覆盖测试。

## Gate

- 对同一本大型 TXT，分别用旧版本（全量解析）和新版本（lazy）恢复到
  同一个 ReadingAnchor，比较恢复后显示的页面内容是否完全一致
  （建议用 page content hash 比较，而不是仅看截图）。
