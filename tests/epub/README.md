# EPUB 兼容性测试记录（ENG-010）

> 状态：`implemented`
>
> 用 EPUBCheck 5.2.1 对真实 EPUB 样本做规格合规校验，记录样本、版本、
> 设备和结果。测试可重复执行：`tests/epub/run_epubcheck.sh`。

## 校验工具

| 项 | 值 |
|----|-----|
| 工具 | EPUBCheck v5.2.1（W3C 官方） |
| 运行环境 | macOS（Apple Silicon），OpenJDK 26 |
| 命令 | `tests/epub/run_epubcheck.sh /path/to/epubcheck.jar [样本目录]` |

## 样本与结果（2026-08-03 快照）

| 样本 | EPUB 版本 | 结果 | 说明 |
|------|-----------|------|------|
| `The_Adventures_of_Sherlock_Holmes_by_Arthur_Conan_Doyle.epub` | 2.0.1 | PASS（0 error / 0 warning） | 合法 EPUB 2 |
| `The_Adventures_of_Sherlock_Holmes_by_Arthur_Conan_Doyle.3.epub` | — | PASS（0 error / 0 warning） | 合法样本 |
| `妹妹人生_上卷.epub`（含 rawfile `test.epub`，同一文件） | 3.3 | FAIL（PKG-007） | mimetype 被压缩，违反 EPUB 规范；引擎可打开 |

详细逐样本输出：`tests/epub/results/*.txt`，汇总：`tests/epub/results/summary.txt`。

## 校验覆盖范围（按 ENG-010 测试范围对照）

| 能力 | 覆盖方式 | 状态 |
|------|----------|------|
| EPUB 2 container / OPF / NCX / Spine | 样本 + OhosTest 解析 | 有样本，解析由 EpubParser 承担 |
| EPUB 3 Nav / HTML5 / CSS / 元数据 | 样本 + 解析测试 | 部分（引擎无独立样本集） |
| CSS @import / @media / 字体 / 选择器 | 核心算法测试（ENG-009）+ EPUBCheck | 部分 |
| 内容：图片 / SVG / 表格 / 列表 / ruby / 上下标 | 渲染测试 | 部分（无独立样本） |
| 异常：缺失文件 / 非法 XML / 损坏压缩包 / 错误路径 | SecureArchive + 解析测试 | 有测试 |
| FXL / Media Overlays / Scripting / MathML | **未实现** | 单独记录，不算失败 |

## 未支持特性记录（不算解析失败）

- **FXL（pre-paginated）**：引擎有 `layout === 'pre-paginated'` 分支，但无完整 FXL
  渲染管线，未做专向兼容测试。
- **完整 Media Overlays（SMIL 音频）**：有 `MediaOverlayController` 骨架，
  未达到完整 EPUB 3 Media Overlays 兼容。
- **Scripting**：不执行 EPUB 内嵌 JavaScript。
- **完整 MathML**：有 `MathMLRenderer` 基础渲染，非完整 MathML 支持。

## 已知缺陷（真实失败）

`妹妹人生_上卷.epub` / rawfile `test.epub` 存在 `PKG-007`：mimetype 被压缩。
该文件由本仓库自带（作为内置测试书），引擎实际可打开阅读；但作为样本它
不符合 EPUB 规范。后续可用 `zip -0` 重新打包 mimetype 后消除该错误。

## 设备与测量说明

- 本快照在 macOS + JDK 26 上运行 EPUBCheck（纯静态校验，不依赖 HarmonyOS 设备）。
- HarmonyOS 端解析/渲染兼容性由 OhosTest（ENG-009）覆盖，需真机执行。
- 性能数据见 ENG-011，不得把本表合规结果当作性能结论。
