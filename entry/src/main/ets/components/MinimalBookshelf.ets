/**
 * MinimalBookshelf — 统一极简书架组件（正式 / 调试共用）
 *
 * 单一实现消除分叉（FR-009）：以导入台账（ImportedBookStore）为数据源，
 * 纯文字列表展示已导入图书，点按打开、长按 + 确认弹窗彻底删除，保留导入入口，
 * 空书架展示极简空态引导。正式书架（pages/Bookshelf）与调试书架
 * （debug/DebugBookshelf）均仅渲染本组件。
 *
 * 关键契约：
 *   - 数据来源：`ImportedBookStore.load(filesDir)` → `projectShelfItems`（FR-002）。
 *   - 点按打开：`router.pushUrl({ url: 'pages/Index', params: { bookPath } })`（FR-003）。
 *   - 长按删除：`AlertDialog.show` 确认 → `ImportService.deleteBook`（FR-004/005/006）。
 *   - 并发防护：`deleting`/`importing` 状态避免重复触发（Edge Cases）。
 */

import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImportService, ImportedBookStore, DeleteStatus } from 'ohrengine-common';
import type {
  ImportRequest, ImportedBook, DeleteResult, BatchImportProgress, BatchImportResult
} from 'ohrengine-common';
import { projectShelfItems } from './ShelfModel';
import type { ShelfItem } from './ShelfModel';

const TAG: string = 'OhEngineEntry';
/** 批量导入多选数量上限（近似“不限制”，实际以系统文件选择器能力为界） */
const MAX_SELECT_NUMBER: number = 100;

@Component
export struct MinimalBookshelf {
  @State books: ShelfItem[] = [];
  @State statusText: string = '';
  @State loading: boolean = true;
  @State importing: boolean = false;
  @State deleting: boolean = false;

  aboutToAppear(): void {
    this.reload();
    this.consumeAutoOpenParam();
  }

  /** 台账 → 书架列表（以导入台账为准，FR-002）；空书架展示极简空态（FR-011） */
  private reload(): void {
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      this.statusText = '无法获取应用上下文';
      this.loading = false;
      return;
    }
    const records: ImportedBook[] = ImportedBookStore.load(hostCtx.filesDir);
    this.books = projectShelfItems(records);
    this.statusText = this.books.length === 0 ? '' : '共 ' + this.books.length + ' 本书';
    this.loading = false;
  }

  /** 调试直达：EntryAbility 注入的 want 参数 bookPath → 直接打开阅读器 */
  private consumeAutoOpenParam(): void {
    const target: string | undefined = AppStorage.get<string>('autoOpenBookPath');
    hilog.info(0x0000, TAG, 'SHELF_CONSUME target=%{public}s',
      target !== undefined ? target : '(none)');
    if (target !== undefined && target.length > 0) {
      AppStorage.setOrCreate('autoOpenBookPath', '');
      this.openPath(target);
    }
  }

  private openPath(path: string): void {
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/Index', params: { bookPath: path }
      });
    } catch (e) {
      this.statusText = '打开失败: ' + (e instanceof Error ? e.message : String(e));
    }
  }

  private openBook(item: ShelfItem): void {
    this.openPath(item.sourcePath);
  }

  /**
   * 导入图书（FR-001/FR-002）：系统文档选择器**多选**（不设小上限）→
   * 唯一统一导入入口 `ImportService.importBooks` 批量导入（逐本复用单本语义）。
   * 完成后刷新列表（FR-010）；0 个文件（取消）不产生任何操作。
   */
  private async importBook(): Promise<void> {
    if (this.importing) {
      return;
    }
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      this.statusText = '无法获取应用上下文';
      return;
    }
    const ctx: Context = hostCtx;
    let uris: string[] = [];
    try {
      const dv: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      uris = await dv.select({
        maxSelectNumber: MAX_SELECT_NUMBER,
        fileSuffixFilters: ['电子书 (.epub/.txt/.cbz)|.epub,.txt,.cbz']
      } as picker.DocumentSelectOptions);
    } catch (e) {
      this.statusText = '选择文件失败/已取消: ' + (e instanceof Error ? e.message : String(e));
      return;
    }
    if (uris === undefined || uris.length === 0) {
      this.statusText = '未选择文件';
      return;
    }
    // 由选中的 URI 列表构造单本请求列表（批量 MUST 经统一入口，禁止绕过自行拷贝/解压/解析）
    const requests: ImportRequest[] = [];
    for (let i = 0; i < uris.length; i++) {
      const req: ImportRequest = { sourceUri: uris[i] };
      requests.push(req);
    }
    this.importing = true;
    this.statusText = '导入中 0/' + requests.length + '...';
    try {
      // 进度（FR-004）：每处理一本更新为「导入中 x/N：书名」
      const result: BatchImportResult = await ImportService.importBooks(ctx.filesDir, requests,
        (p: BatchImportProgress): void => {
          this.statusText = '导入中 ' + (p.index + 1) + '/' + p.total + '：' + p.name;
        });
      // 结束汇总（FR-004）：成功 / 已存在 / 失败（不支持）
      const summary: string = '成功 ' + result.succeeded + ' / 已存在 ' + result.alreadyImported +
        ' / 失败 ' + result.failed + '（不支持 ' + result.unsupported + '）';
      hilog.info(0x0000, TAG,
        'SHELF_BATCH total=%{public}d success=%{public}d already=%{public}d unsupported=%{public}d failed=%{public}d',
        result.total, result.succeeded, result.alreadyImported, result.unsupported, result.failed);
      this.reload();
      // reload 会重置 statusText，汇总在刷新之后回填以保证可见
      this.statusText = summary;
      this.importing = false;
    } catch (e) {
      this.statusText = '导入失败: ' + (e instanceof Error ? e.message : String(e));
      this.importing = false;
    }
  }

  /** 长按 → 删除确认弹窗（取消 / 删除）（FR-004） */
  private confirmDelete(item: ShelfItem): void {
    if (this.deleting) {
      return;
    }
    AlertDialog.show({
      title: '删除图书',
      message: '将彻底删除「' + item.title +
        '」及其全部关联数据（源文件、缓存、台账、阅读进度、批注/书签），此操作不可恢复。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          this.performDelete(item);
        }
      }
    });
  }

  /** 彻底删除（唯一删除入口）→ 依据结果刷新列表并提示 */
  private async performDelete(item: ShelfItem): Promise<void> {
    if (this.deleting) {
      return;
    }
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      this.statusText = '无法获取应用上下文';
      return;
    }
    const ctx: Context = hostCtx;
    this.deleting = true;
    this.statusText = '删除中: ' + item.title;
    try {
      const result: DeleteResult = await ImportService.deleteBook(ctx.filesDir, item.bookId, {
        readingStateDir: ctx.filesDir + '/reading_state'
      });
      if (result.status === DeleteStatus.NOT_FOUND) {
        this.statusText = '该书已不存在，已刷新列表';
      } else if (result.status === DeleteStatus.FAILED) {
        this.statusText = '删除失败，请重试';
      } else if (result.status === DeleteStatus.PARTIAL) {
        this.statusText = '已删除（部分清理失败：' + result.failedItems.join(',') + '）';
      } else {
        this.statusText = '已删除: ' + item.title;
      }
      hilog.info(0x0000, TAG, 'SHELF_DELETE bookId=%{public}s status=%{public}s',
        item.bookId, result.status);
      this.reload();
      this.deleting = false;
    } catch (e) {
      this.statusText = '删除失败: ' + (e instanceof Error ? e.message : String(e));
      this.deleting = false;
    }
  }

  build() {
    Column() {
      // 标题栏（标题 + 「导入」按钮）
      Row() {
        Text('书架')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
        Blank()
        Button('导入')
          .fontSize(15)
          .height(40)
          .margin({ right: 4 })
          .backgroundColor('#0078D4')
          .onClick(() => {
            this.importBook();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 24, bottom: 16 })

      if (this.importing || this.deleting) {
        Row() {
          LoadingProgress().width(18).height(18).margin({ right: 8 })
          Text(this.statusText)
            .fontSize(14)
            .fontColor('#0078D4')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .margin({ bottom: 8 })
      }

      if (this.loading) {
        LoadingProgress().width(32).height(32).margin({ top: 60, bottom: 16 })
      } else if (this.books.length === 0) {
        Column() {
          Text('[ 空书架 ]')
            .fontSize(36).fontColor('#cccccc').margin({ top: 60, bottom: 16 })
          Text('点击右上角「导入」，从文件管理器选择 .epub / .txt / .cbz 图书')
            .fontSize(14).fontColor('#888888')
            .margin({ left: 24, right: 24 })
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      } else {
        List() {
          ForEach(this.books, (item: ShelfItem) => {
            ListItem() {
              Text(item.title)
                .fontSize(16)
                .fontColor('#222222')
                .width('100%')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .height(52)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.openBook(item);
            })
            .gesture(LongPressGesture({ repeat: false }).onAction(() => {
              this.confirmDelete(item);
            }))
          }, (item: ShelfItem) => item.bookId)
        }
        .layoutWeight(1)
        .width('100%')
        .divider({ strokeWidth: 0.5, color: '#E0E0E0' })
      }

      Text(this.statusText)
        .fontSize(12)
        .fontColor('#999999')
        .margin({ top: 8, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}
