# 附录 — 反作弊清单 与 Definition of Done

> 本文件贯穿 Phase 9.0 - 9.9 全程，每个阶段结束前都应对照检查。

## 反作弊清单：以下行为全部禁止

### 1. 只把 readAll 放到后台线程

如果结果仍然是"整本 TXT → 全内存"，则不算解决问题——只是把阻塞点
从主线程挪到了后台线程，内存问题原封不动。

### 2. 把全文放进 L0 Cache

这只是换名字，不是 lazy loading。判断标准：首次打开时是否触发了
"生成全部 chunk / 全部 vchapter"的行为，而不是看数据最终存在哪个
Cache 对象里。

### 3. 把全文拆成很多 String

例如 `wholeText → split("\n") → 500万个 String`，仍然是 eager
loading，只是把一个大对象换成了大量小对象，总内存和阻塞时间不变。

### 4. 首屏完成后立即后台生成整本 TXT cache

这会让 RSS / CPU / IO 重新失控，等同于把 eager loading 延迟了几百
毫秒执行，而不是真正做到按需加载。

### 5. 只测试 10MB

本阶段必须至少验证 200MB TXT，小文件测试无法暴露 eager
loading 问题。

### 6. 只看页面截图

必须做逻辑一致性验证（如 page content hash 比较），截图无法发现
"内容正确但底层仍是全量加载"的情况。

### 7. 为了解决问题修改分页算法

禁止。TextBreaker / Knuth-Plass / 分页算法属于严格禁止修改区域
（见 `00-overview.md` 第三节）。

---

## Definition of Done

只有同时满足以下条件，本阶段才能标记 PASS。

### 架构

- [ ] TXT 不再依赖 whole-file String 作为 Reader Session 的长期数据源
- [ ] 存在 Lightweight Index
- [ ] VirtualChapter 可以通过 offset 定位
- [ ] Chunk 可以按需读取
- [ ] Chunk 生命周期受控（含并发/引用计数保护，见 9.6）
- [ ] L0 不再触发整本预生成

### 性能

- [ ] 大型 TXT 首屏不再出现数秒级主线程阻塞
- [ ] `THREAD_BLOCK_6S` 已消失或显著降低，并有数字证明
- [ ] RSS 不随阅读进度线性增长
- [ ] 200MB TXT 已真实设备验证
- [ ] 随机跳转不需要从文件头重新解析
- [ ] 连续阅读 100 页后 RSS 仍在预算范围内

### 正确性

- [ ] 首屏正确
- [ ] 随机跳转正确
- [ ] ReadingAnchor 恢复正确
- [ ] paragraphHash correction 正常
- [ ] Cache ON/OFF 页面结果一致
- [ ] UTF-8 正确 / BOM 正确 / 换行符正确
- [ ] 超长段落正确（含跨多 chunk 上限保护，见 9.2）
- [ ] 并发压力测试通过，无崩溃/死锁/数据错乱（见 9.6）

### 兼容性与可回退性

- [ ] API24 可用 / API26+ 可用
- [ ] EPUB 行为没有回归
- [ ] TextBreaker 没有被重写
- [ ] Knuth-Plass 没有被重写
- [ ] 页面动画没有被修改
- [ ] 存在可用的灰度回退开关（见 9.9），并已实测回退路径
