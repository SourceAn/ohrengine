# Phase 9.0 — 审计（Gate：未完成不允许进入 9.1）

> 前置阅读：`00-overview.md`

## 目标

在改任何代码之前，先证明现状。输出文档：

```
docs/phase9-txt-lazy-audit.md
```

## 必须回答的问题

1. 当前 TXT 数据流是什么？（从打开文件到显示第一页的完整链路）
2. 哪一步产生 whole-file String？
3. 哪一步产生全量 paragraph？
4. 哪一步产生全量 vchapter？
5. 哪一步造成 `THREAD_BLOCK_6S`？
6. 哪些对象长期持有全文？（给出类名 / 字段名 / 生命周期）
7. L0 当前到底缓存什么？（是内容本身，还是 offset/索引）
8. ReadingAnchor 如何定位 TXT？（当前字段语义：chapterId /
   paragraphIndex / paragraphHash / charOffset 等）
9. 当前 TextBreaker 的输入是什么？（字符串？段落数组？是否要求连续文本？）
10. 最小修改点在哪里？（哪一层可以插入 lazy 逻辑而不动 TextBreaker/分页/动画）

## 定位清单（辅助第 1-10 题）

- 当前 TXT 导入流程入口
- `TxtParser` 具体实现
- TXT 文件读取 API（同步/异步、是否支持 range read）
- 全文字符串 / 全量段落 / 全量 HTML 的持有位置
- vchapter 创建位置
- 分页入口
- L0 chunk 的生成和读取路径
- 阅读位置恢复路径
- 现有 benchmark instrumentation（若无需注明"缺失"，并在报告中说明后续如何补）

## 输出格式要求

- 每条结论必须附带文件路径 + 行号或函数名，不接受"大概在解析模块里"这种模糊描述。
- 数据流用简单的文本箭头图表示（`A → B → C`），标注每一步产生的数据结构和大小量级。
- 明确标注哪些结构目前是"全量常驻"，哪些已经是"按需/分块"。

## Gate

**没有完成审计文档并经过确认，不允许开始 Phase 9.1 的大规模修改。**
