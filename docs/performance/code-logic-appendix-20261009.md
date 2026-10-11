# 附录：打开链路的项目代码逻辑（供分析）

> 生成：2026-10-09 ｜ 对应审计报告：`ohrengine-open-latency-audit-20261009.md`
> 目的：把"从点击到首帧"经过的每一层代码逻辑摊开，标注问题点（🔴/🟡）与行号，便于定位与评审。
> 仓库：`$HOME/Code/Harmony/Project/ohrengine`（多 HAR 模块 + entry HAP）

---

## 0 链路总览

```
点击书架项
  └─ EntryAbility.onCreate                    entry/entryability/EntryAbility.ets
  └─ 页面：index/DebugBookshelf → pages/Index   （路由 + 参数）
  └─ ReaderHost.doInitEngine()                ohrengine-reader/ReaderHost.ets:538
       ├─ hilog SESSION_INIT_START            :541        ← 本报告所有耗时口径的 T0
       ├─ prepareWindowAndViewport()          :543
       ├─ resolveBookSource()                 :630   ★★★ 解压 + 缓存判断全在这里
       └─ openAndLoad()                       :705
            └─ engine.open(basePath, {sourcePath, cacheDir, readingStateDir})
                 └─ OhEngineCore.open()       ohrengine-ui-render/OhEngineCore.ets:810
                      ├─ ParserRegistry.resolveByExtension(ext)   :815
                      ├─ 目录探测（EPUB container.xml / 图片目录） :818-833
                      ├─ EPUB 分块缓存命中（仅 EPUB）              :857-890
                      ├─ TXT lazy 分支（索引）                     :899-960
                      └─ 回退全量 parse（parser.parse）
                           ├─ CbzParser.parse / EpubParser.parse
                           └─ SecureArchive.decompressArchive（CBZ 文件输入时）
```

---

## 1 `ReaderHost.doInitEngine()` —— 时序基准点

`ohrengine-reader/src/main/ets/ReaderHost.ets:538-570`

```ts
private async doInitEngine(): Promise<void> {
  if (this.pageDestroyed) { return; }
  const hostCtx: Context | undefined = this.getUIContext().getHostContext();
  if (hostCtx === undefined) { this.errorMsg = '获取应用上下文失败'; return; }
  const ctx: Context = hostCtx;
  hilog.info(0x0000, READER_TAG, 'SESSION_INIT_START');        // :541  ★ 打点在解压之前
  try {
    const viewportOk: boolean = await this.prepareWindowAndViewport(ctx);
    if (!viewportOk) { return; }
    const src: BookSource | undefined = await this.resolveBookSource(ctx);   // :546 ★ 解压在这里
    if (this.pageDestroyed || src === undefined) { return; }
    ...
```

**要点**：`SESSION_INIT_START` 打在 `resolveBookSource()`（解压）之前，因此
`SESSION_INIT_START → OPEN_TOTAL` 是**从"准备打开"到"页面可显示"的完整耗时（含解压）**，且不含任何人为等待 —— 这是唯一可信的日志口径。

---

## 2 🔴 `ReaderHost.resolveBookSource()` —— 缓存判断把 CBZ/CBR 排除在外

`ohrengine-reader/src/main/ets/ReaderHost.ets:630-702`

```ts
const lowerPath: string = this.bookPath.toLowerCase();
if (lowerPath.endsWith('.txt')) {                                 // TXT：直接用源文件
  bookBasePath = this.bookPath; sourcePath = this.bookPath;
} else if (lowerPath.endsWith('.pdf')) {
  this.errorMsg = 'PDF 暂不支持（当前仅 EPUB / TXT）'; return undefined;   // :652-655 PDF 未实现
} else {                                                          // EPUB / CBZ / CBR 统一走 ZIP 解压
  const bookFileName: string = this.bookPath.substring(this.bookPath.lastIndexOf('/') + 1);
  const archivePath: string = booksDir + '/' + bookFileName;
  let needCopy: boolean = true;
  try { /* 与 books/ 下同名文件比 size，不同才拷贝 */ } catch (_e) { needCopy = true; }
  if (needCopy) { fileIo.copyFileSync(this.bookPath, archivePath); }

  const extractDir: string = booksDir + '/' + bookFileName + '_extracted';

  // ↓↓↓ ★★★ 三处 endsWith('.epub') 就是 CBZ/CBR 永不命中缓存的根因 ★★★
  const fpValid: boolean = lowerPath.endsWith('.epub') &&
    ParseCacheManager.isFingerprintValid(extractDir, archivePath);            // :675
  const unzipDone: boolean = lowerPath.endsWith('.epub') &&
    ImportCheckpoint.isStageDone(extractDir, ImportStage.UNZIP_DONE);         // :677
  const cacheHit: boolean = fpValid && (unzipDone || !lowerPath.endsWith('.epub'));  // :679

  if (cacheHit) {
    this.engineState = '缓存命中，跳过解压...';
  } else {
    removeDirRecursive(extractDir);                     // 删掉上一次解压产物
    fileIo.mkdirSync(extractDir, true);
    try {
      await SecureArchive.decompressArchive(archivePath, extractDir, ctx.filesDir);  // :686 ★ 全量解压，await 阻塞
    } catch (e) { this.errorMsg = '解压外部文件失败：...'; return undefined; }
    ImportCheckpoint.markStage(extractDir, ImportStage.UNZIP_DONE);      // :692 解压完成才标记
    ParseCacheManager.writeFingerprint(extractDir, archivePath);         // :693
  }
  bookBasePath = extractDir;
  this.pageRenderer.setBookBasePath(bookBasePath);
  if (lowerPath.endsWith('.epub')) { sourcePath = archivePath; }         // :697-699
}
```

**问题（对应审计报告 R1/R2）**

| 位置 | 逻辑 | 后果 |
|---|---|---|
| :675 / :677 / :679 | `endsWith('.epub')` 门控 | CBZ/CBR 的 `fpValid=false` ⇒ `cacheHit=false` ⇒ **每次打开都 `removeDirRecursive` + 全量解压** |
| :686 | `await decompressArchive(...)` 在首帧之前 | 解压时长直接加在"点击→首帧"上（实测 CBZ 313MB ≈ 1.7s；TXT 则见 §7） |
| :692 | `UNZIP_DONE` 只在**全量解压完成后**标记 | 解压中途退出 → 下次从零重来 |
| :683 | `removeDirRecursive` 无条件删除 | 即使上次解压完整（checkpoint 全绿）也照样删（实测已验证） |

**机制本身没问题**（所以修复成本很低）：
- `ParseCacheManager.isFingerprintValid(cacheDir, sourcePath)`：比对源文件 `size+mtime` 与 `<cacheDir>/fingerprint.json`，**与格式无关**
- `ImportCheckpoint.markStage`：`tmp + renameSync` **原子写**；`isStageDone` 读 `checkpoint.json`
- 二者对 CBZ 同样适用 —— 只是被 `endsWith('.epub')` 挡住了

---

## 3 `ReaderHost.openAndLoad()` / `setupThemeAndListeners()`

`ohrengine-reader/src/main/ets/ReaderHost.ets:705-767`

```ts
private async openAndLoad(ctx: Context, sourcePath: string, bookBasePath: string): Promise<void> {
  const bookName: string = ...;
  const pageCacheDir: string = ctx.filesDir + '/cache/books/' + bookName;   // L2/L3 页缓存目录
  const readingStateDir: string = ctx.filesDir + '/reading_state';          // 阅读位置（独立目录）
  const pub = await this.engine.open(bookBasePath, {
    sourcePath: sourcePath.length > 0 ? sourcePath : undefined,
    cacheDir: pageCacheDir,
    readingStateDir: readingStateDir
  });                                                                        // ★ 引擎打开
  if (bookBasePath.length > 0) {
    ImportCheckpoint.markStage(bookBasePath, ImportStage.PARSE_DONE);        // :724
    ImportCheckpoint.markStage(bookBasePath, ImportStage.CACHE_DONE);        // :725
  }
  ...
  hilog.info(0x0000, READER_TAG, 'OPEN_TOTAL page=%d total=%d', this.currentPageNum, this.totalPages);  // :743 ★ 本报告终点
  this.pageRenderer.renderPage();
  if (this.featureFlags.anchorFirst) {
    hilog.info(0x0000, READER_TAG, 'COLDSTART FIRST_FRAME ...');              // :748
    this.engine.scheduleBackgroundReflow();                                  // 后台增量排版
  }
}
```

**注意**：`PARSE_DONE`/`CACHE_DONE` 是**打开成功后无条件标记**的（不校验真实产物）——与注释里"非 correctness source"一致，但意味着 checkpoint 不能单独作为"可跳过"的证据（`ReaderHost:679` 也确实要求 `fpValid && unzipDone` 双条件）。

---

## 4 `OhEngineCore.open()` —— 解析器解析与解析缓存

`ohrengine-ui-render/src/main/ets/OhEngineCore.ets:810-895`

```ts
// Step 1: 按扩展名解析；失败则按目录内容探测
const extIndex: number = bookBasePath.lastIndexOf('.');
const ext: string = extIndex >= 0 ? bookBasePath.substring(extIndex).toLowerCase() : '';
let parser: BookParser | undefined = ParserRegistry.resolveByExtension(ext);   // :815
if (parser === undefined) {
  const stat = fileIo.statSync(bookBasePath);
  if (stat.isDirectory()) {
    fileIo.statSync(bookBasePath + '/META-INF/container.xml');                 // 是 EPUB 目录？
      → parser = ParserRegistry.resolve(BookFormat.EPUB);
    if (parser === undefined && this.isComicImageDir(bookBasePath))            // 是图片目录？
      → parser = ParserRegistry.resolve(BookFormat.CBZ);                       // :829-833
  }
}

// Step 2: 解析缓存（仅 EPUB）—— L0 分块缓存优先
const parseCacheDir: string = opts?.cacheDir ?? bookBasePath;
const parseSourcePath: string = opts?.sourcePath ?? bookBasePath;
const chunkedValid: boolean = parser.format === BookFormat.EPUB &&
  ParseCacheManager.isChunkedValid(parseCacheDir, parseSourcePath);            // :857 ★ 仅 EPUB
if (chunkedValid) {
  const meta = ParseCacheManager.loadParseMeta(parseCacheDir);                 // :860 只加载 meta
  // 用 meta 重建最小 ParsedBook：chapters.content='' ，内容按需 provider 加载
  this.pipelineManager.chapterHtmlProvider = (ci) =>
    ParseCacheManager.loadParseChapter(parseCacheDir, ci)?.content;            // :879-883
  ...
}
if (parsedBook === null) {
  if (parser.format === BookFormat.EPUB) parsedBook = ParseCacheManager.loadParsedBook(parseCacheDir);  // :894 旧版整书缓存回退
  // ★ 注意：CBZ 没有任何解析缓存分支 → 必然走全量 parse
}
```

**问题（对应 R1 的第二层）**
- `chunkedValid` / `loadParsedBook` **只对 EPUB 生效** → CBZ 永远全量重建章节结构（200 页 = 200 次 `statSync` + 数组构建，实测约 0.2–1.7s 中的一部分）。
- 目录探测分支（:829-833）说明"CBZ 以解压目录形态打开"是设计内行为 → 意味着**解压是必经步骤**，更应缓存。

---

## 5 `CbzParser.parse()` —— 文件输入时会自己解压一次

`ohrengine-cbz-exclusive/src/main/ets/CbzParser.ets:34-92`

```ts
public async parse(filePath: string): Promise<ParsedBook> {
  if (this.directoryExists(filePath)) {
    return this.buildBookFromImages(filePath);            // 目录输入：直接扫描（正常路径，因为 ReaderHost 已解压）
  }
  const extractDir: string = filePath + '.extracted';     // ★ 命名与 ReaderHost 不一致（点号 vs 下划线）
  this.removeExtractDir(extractDir);
  fileIo.mkdirSync(extractDir, true);
  await SecureArchive.decompressArchive(filePath, extractDir);   // ★ 又解压一次（若传入的是文件）
  return this.buildBookFromImages(extractDir);
}

private buildBookFromImages(extractDir: string): ParsedBook {
  const imageFiles: string[] = this.listImageFiles(extractDir);   // listFileSync + 逐条 statSync + 自然排序
  const chapters: ChapterData[] = [];
  const imagePaths: string[] = [];
  for (let i = 0; i < imageFiles.length; i++) {
    chapters.push({ title: 'Page ' + (i+1), content: '', href: fullPath, imagePaths: [fullPath] });  // 每图一章
  }
  return new ParsedBook(BookFormat.CBZ, RenderStrategy.IMAGE, null, chapters, [], imagePaths);
}
```

**要点**
- 正常链路传入的是 `ReaderHost` 解压好的目录 → 走 `buildBookFromImages`，**不再解压**。
- 但存在两套解压目录命名（`<file>.extracted` vs `<name>_extracted`），是历史双路径残留，清理缓存时需两者都覆盖。
- `listImageFiles` 对每张图 `statSync`（200 页 = 200 次同步 IO），是"全量 parse"的一部分成本。

---

## 6 `EpubParser.parse()` —— 全量读章节 + CSS（仅无缓存时）

`ohrengine-epub/src/main/ets/parser/EpubParser.ets:146-189`

```ts
public async parse(filePath: string): Promise<ParsedBook> {
  const publication: Publication = await this.parseFromDir(filePath);   // container → OPF → spine → NCX/nav
  const chapters: ChapterData[] = []; const cssTexts: string[] = [];
  for (const link of publication.manifest.readingOrder) {                // ★ 逐章读文件内容（全量）
    content = this.readTextFileSync(filePath + '/' + link.href);
    chapters.push({ title, content, href });
  }
  for (const resource of publication.manifest.resources) {               // ★ 收集全部 CSS
    if (resource.mediaType === 'text/css') cssTexts.push(this.readTextFileSync(...));
  }
  return new ParsedBook(BookFormat.EPUB, RenderStrategy.REFLOW, publication, chapters, cssTexts);
}
```

**要点**：EPUB 的"全量 parse"成本与书内文件数成正比，因此**才更需要** §4 的分块缓存 —— 而它已经实现且实测有效（第二次打开 43ms、跳过解压）。**CBZ 缺的正是与之对等的缓存层。**

---

## 7 `SecureArchive.decompressArchive()` —— 解压本体

`ohrengine-common/src/main/ets/service/SecureArchive.ets:36-118`

```ts
const DEFAULT_LIMITS = { maxArchiveBytes: 1GB, maxEntries: 50000,
                         maxSingleFileBytes: 256MB, maxTotalBytes: 2GB };   // :36-41

static async decompressArchive(archivePath, extractDir, sandboxBase?, limits?) {
  const archiveSize = safeStatSize(archivePath);              // 校验存在/非空/不超上限
  if (sandboxBase) { if (!isSubPath(extractDir, sandboxBase)) throw ...; }   // 沙箱边界
  removeDirRecursive(extractDir);                             // ★ 无条件清旧
  fileIo.mkdirSync(extractDir, true);
  await zlib.decompressFile(archivePath, extractDir, {});      // :105 ★ zlib = ZIP/deflate
  validateExtractTree(extractDir, lim);                        // :113 ★ 后置整树遍历校验（逐条 lstat）
}
```

**要点**
- `zlib.decompressFile` 只能处理 ZIP/deflate → **CBR（RAR）必然失败**（对应 R3）。
- `validateExtractTree` 对解压产物**整树递归 `lstat`**（200 文件 = 200 次）→ 解压后多一轮全量 IO。
- `maxTotalBytes = 2GB`、`maxEntries = 50000` 是硬上限，超限直接抛错并清理。

---

## 8 缓存与检查点的两个实现（修复的现成基础）

### 8.1 指纹（通用，不限格式）

`ohrengine-common/src/main/ets/service/ParseCacheManager.ets:335-373`

```ts
static isFingerprintValid(cacheDir: string, sourcePath: string): boolean {
  try {
    const stat = fileIo.statSync(sourcePath);
    const cached = ParseCacheManager.readFingerprint(cacheDir);
    if (cached === null) return false;
    return cached.size === stat.size && cached.mtime === stat.mtime;     // ★ 只比 size+mtime
  } catch (_e) { return false; }
}
static writeFingerprint(cacheDir: string, sourcePath: string): void {
  const data = { size: stat.size, mtime: stat.mtime };
  // 先 unlink 再 CREATE/WRITE_ONLY/TRUNC 写 fingerprint.json（★ 非原子，失败静默）
}
```

### 8.2 导入阶段检查点（已是原子写）

`ohrengine-common/src/main/ets/service/ImportCheckpoint.ets:15-96`

```ts
export enum ImportStage { UNZIP_DONE, PARSE_DONE, INDEX_DONE, CACHE_DONE }
static markStage(bookDir, stage) {
  const current = loadStages(bookDir); if (!current.includes(stage)) current.push(stage);
  // tmp 写入 → fileIo.renameSync(tmp, target)   ★ 原子提交
}
static isStageDone(bookDir, stage): boolean { return loadStages(bookDir).indexOf(stage) >= 0; }
static loadStages(bookDir): string[]  // 缺失/损坏 → []（不抛错）
```

**结论**：想修 CBZ 只需在 `ReaderHost:675-679` 把"ZIP 类格式"（epub/cbz/cbr）纳入 `fpValid/unzipDone`，无需新建机制。

---

## 9 🟡 `DiskCacheQuotaManager` —— 托管范围不含解压产物

`ohrengine-common/src/main/ets/service/DiskCacheQuotaManager.ets:16-96`

```ts
const DEFAULT_MANAGED_DIRS: string[] = ['cache/books', 'reading_state'];   // ★ 不含 books/*_extracted
constructor(maxGlobalBytes = 512MB, maxPerBookBytes = 128MB, managedRoots?) { ... }

enforceGlobalQuota(baseDir) {           // 每次打开前调用（ReaderHost:641-642）
  for (root of managedRoots) {
    names = listFileSync(baseDir + '/' + root);
    for (name of names) { size = dirSize(dirPath); access = stat.atime || stat.mtime; }  // ★ 递归 stat
    if (total > maxGlobalBytes) { LRU 淘汰最旧 }
  }
}
enforceBookQuota(bookCacheDir) { if (dirSize > maxPerBookBytes) removeDir; }   // 仅 cache/books
```

**结论**
- 解压产物（实测 299MB/本）**不在托管范围**：既不参与淘汰、也无人清理。
- `enforceGlobalQuota` 每次打开都跑一次**全量递归 `dirSize`**（逐文件 `statSync`）。本次实测 `cache/books` 仅 63 文件/3.2MB → 影响可忽略，但**书多/缓存大时会成为固定开销**，且没有任何结果缓存或脏标记。

---

## 10 🔴 TXT 路径：首帧被索引 `await` gate + 索引只在完成后落盘

### 10.1 `TxtDocument.open()`（磁盘索引命中与否）

`ohrengine-txt-exclusive/src/main/ets/TxtDocument.ets:32-114`

```ts
const INDEX_FILE: string = 'txt-index-v2.json';

static async open(filePath: string, cacheDir: string): Promise<TxtDocument | undefined> {
  const doc = new TxtDocument(cacheDir); doc.filePath = filePath;
  const disk = TxtDocument.tryLoadDiskIndex(filePath, cacheDir);      // 读 cacheDir/txt-index-v2.json
  if (disk !== null) {                                                // 指纹：size + mtime
    doc.indexData = disk; doc.reader = new TxtChunkReader(filePath, disk.encoding); return doc;
  }
  // ★ 未命中 → 等索引构建完成（在 TaskPool 里，但这里 await）
  const built = await TxtIndexBuilderTask.buildInTaskPool(filePath);
  if (built === null) return undefined;
  doc.indexData = built; doc.reader = new TxtChunkReader(filePath, built.encoding);
  TxtDocument.saveDiskIndex(filePath, cacheDir, built);               // :68 ★ 构建全部完成后才写盘
  return doc;
}
```

**问题（R5）**
- `await` 在 `open()` 内 ⇒ 首帧等索引：实测 52MB → `txtLazyIdxMs=89172`，首帧 91.14s。
- `saveDiskIndex` 在 `buildInTaskPool` **返回之后**才调用 ⇒ 中途打断（强杀/切走）则**索引全废**，下次重来。
- 落盘非原子（`CREATE|TRUNC` 直接写 `txt-index-v2.json`，:105-106），写一半崩溃会留下坏索引（靠 `fromJson` 失败回退，代价是全量重建）。

### 10.2 `TxtIndexBuilder.build()` —— 两遍全文件扫描

`ohrengine-txt-exclusive/src/main/ets/TxtIndexBuilder.ets:601-665`

```ts
static async build(filePath: string): Promise<TxtIndexData | null> {
  const stat = fileIo.statSync(filePath); const fileSize = stat.size;
  file = fileIo.openSync(filePath, READ_ONLY); const fd = file.fd;
  const sample = new Uint8Array(Math.min(fileSize, 64*1024));
  fileIo.readSync(fd, sample.buffer, {...});
  const encoding = TxtEncodingDetector.detect(sample);

  // Pass1：只为统计标题行数（决定 detectedMode = headingCount >= 2）
  const s1 = new TxtLineScanner(fd, fileSize, encoding);
  while ((l1 = await s1.nextLine()) !== null) {
    if (quickHeadingTest(l1.text) && TxtChapterDetector.isHeadingLineFor(l1.text)) headingCount++;
    if (++pass1Regions % 64 === 0) await new Promise(r => setTimeout(r, 1));   // ★ 已迁 TaskPool 仍让出
  }
  const detectedMode = headingCount >= 2;

  // Pass2：全文建链
  const s2 = new TxtLineScanner(fd, fileSize, encoding);
  const engine = new TxtVchEngine(detectedMode); engine.beginChapter();
  while ((l2 = await s2.nextLine()) !== null) {
    engine.onLine(l2);
    if (++pass2Regions % 96 === 0) await new Promise(r => setTimeout(r, 1));   // ★ 同上
  }
  engine.finish();
  return engine.toIndex(fileSize, encoding);
}
```

### 10.3 `TxtLineScanner` —— 每字节被 JS 循环处理 5 遍

`ohrengine-txt-exclusive/src/main/ets/TxtIndexBuilder.ets:40-238`

| 方法 | 行号 | 行为 | 代价 |
|---|---|---|---|
| `fill()` | :100-121 | `for (i<readLen) this.pending.push(buf[i])` | 逐字节 push 到 `number[]`（128KB 窗口 = 131072 次） |
| `lastUnitStart()` | :85-98 | 逐字节调 `unitLenAt()` 找换行 | 每窗口再扫 131072 次 |
| `decodeRegion()` | :124-130 | 逐字节复制进新 `Uint8Array` | 第三遍 |
| `emitDecoded()` | :133-157 | 逐字节收 units + 两次 `new RegExp` replace + `split('\n')` | 第四遍 + 整区间正则 |
| `processRegion()` | :195-216 | 重建 `remain` 数组逐字节 push | 第五遍 |
| `nextLine()` | :160-193 | 每行一次 `await`（async 函数） | 行数级微任务 |

**可替代的原生路径**：`Uint8Array.indexOf(0x0A)`、`subarray()`（零拷贝）、游标（不重建 remain）、预编译正则常量。
**已确认非主因**：索引跑在 `TxtIndexBuilderTask.buildInTaskPool`（`@Concurrent` + `taskpool.execute`），主线程未被冻结（实测 0 THREAD_BLOCK）。

---

## 11 `ParserRegistry` —— `.cbr` 被映射到 CBZ

`ohrengine-common/src/main/ets/parser/ParserRegistry.ets:208-218`（实例方法）与 `:293-301`（静态方法）

```ts
const formatMap: Record<string, BookFormat> = {
  '.epub': BookFormat.EPUB,
  '.txt':  BookFormat.TXT,
  '.cbz':  BookFormat.CBZ,
  '.cbr':  BookFormat.CBZ,      // ★ 映射到 CBZ → 走 zlib 解压 → 真 RAR 必失败
};
```

**对应 R3**：项目无任何 RAR 解压依赖（已 grep 确认），因此 `.cbr` 属"名义支持"。

---

## 12 问题清单（与审计报告 R1–R5 对齐）

| ID | 位置 | 问题 | 修复方向 |
|---|---|---|---|
| R1 | `ReaderHost.ets:675-679` | `endsWith('.epub')` 把 CBZ/CBR 排除在解压缓存外 ⇒ 每次全量重解压 | 改为"ZIP 类格式"（epub/cbz/cbr）共享 `fpValid && unzipDone` |
| R2 | `ReaderHost.ets:686` | `await decompressArchive` 在首帧路径上 | 首屏先行 / 导入阶段后台解压 / 部分可用 |
| R3 | `ParserRegistry.ets:213/298` + `SecureArchive.ets:105` | `.cbr` → CBZ → `zlib`（仅 ZIP） | 引入 RAR 能力，或显式不支持并提示 |
| R4 | `DiskCacheQuotaManager.ets:16` | `books/*_extracted` 不在托管目录 ⇒ 299MB/本 永久残留 | 纳入托管（可 LRU / 可清理） |
| R5 | `TxtDocument.ets:61/68` + `TxtIndexBuilder.ets:601-665` | 首帧 `await` 索引；索引仅完成后落盘且非原子；扫描逐字节 5 遍 + 两遍全文 | 部分索引先行（头部 ≤512KB）+ 增量/原子落盘 + 扫描改原生 API |

---

## 13 附：本次测试用到的设备侧埋点（口径来源）

| 埋点 | 位置 | 含义 |
|---|---|---|
| `SESSION_INIT_START` | `ReaderHost.ets:541` | 引擎初始化开始（**解压之前**） |
| `SESSION_OPEN id=N book=...` | `OhEngineCore.ets` | `engine.open()` 入口（传出的是解压后目录） |
| `OPEN_TOTAL page=1 total=N` | `ReaderHost.ets:743` | 可显示页数确定（**首帧前一步**） |
| `COLDSTART FIRST_FRAME ...` | `ReaderHost.ets:748` | 首帧（含 N-1/N/N+1 就绪快照） |
| `COLDSTART BACKGROUND_REFLOW_START/CHAPTER/END` | `OhEngineCore`/`PipelineManager` | 后台增量排版进度 |
| `CacheStats[open] ... openMs= restoreMs= txtLazyIdxMs=` | `OhEngineCore.ets:390` | 缓存摘要；**`openMs/restoreMs` 恒 0 = 埋点失效，勿引用** |
| `TXT-LAZY open chapters= vchs= idx=size=` | `OhEngineCore.ets:961` | TXT 惰性索引就绪 |
| `LAYOUT_WORKER_END/COMPUTE ... ms=` | `LayoutChapterWorker` | 章级排版耗时（Worker 内） |
