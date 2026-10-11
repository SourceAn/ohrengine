/**
 * AnnotationListPage — 标注列表页
 *
 * 功能：
 *   1. 按章节分组展示全书标注
 *   2. 每个标注项显示颜色条、文本、笔记
 *   3. 侧滑删除
 *   4. 点击跳转到对应位置
 *
 * 路由参数：
 *   - 无需序列化参数；engine 引用通过 AppStorage 传递
 *
 * 使用方式（在 Index.ets 中）：
 *   import { AnnotationListPage } from './AnnotationListPage.ets';
 *   // router.pushUrl 或直接 Navigation.pushPath
 */

import { Annotation } from 'ohrengine-common';
import { OhEngine } from 'ohrengine-ui-render';
import { router } from '@kit.ArkUI';

// ── 模块级持有 engine 引用（router 不能传递对象引用） ──
let _pageEngine: OhEngine | undefined = undefined;

/**
 * 设置 AnnotationListPage 使用的 engine 实例。
 * 必须在 push 页面之前调用。
 */
export function setAnnotationPageEngine(e: OhEngine): void {
  _pageEngine = e;
}

// ── 章节分组接口 ──
export interface ChapterAnnotationGroup {
  chapterIndex: number;
  title: string;
  annotations: Annotation[];
}

// ── 标注列表页组件 ──
@Component
export struct AnnotationListPage {
  @State groups: ChapterAnnotationGroup[] = [];

  aboutToAppear(): void {
    this.loadAnnotations();
  }

  /**
   * 从 engine 读取标注并分组
   */
  private loadAnnotations(): void {
    const engine: OhEngine | undefined = _pageEngine;
    if (engine === undefined) {
      return;
    }
    const allAnns: Annotation[] = engine.getAnnotations();
    if (allAnns.length === 0) {
      return;
    }
    // 过滤可见标注
    const visibleAnns: Annotation[] = [];
    for (let i: number = 0; i < allAnns.length; i++) {
      const a: Annotation = allAnns[i];
      const vis: number | undefined = a.isVisible;
      if (vis === undefined || vis !== 0) {
        visibleAnns.push(a);
      }
    }
    // 收集不重复的章节索引
    const chapterSet: number[] = [];
    for (let i: number = 0; i < visibleAnns.length; i++) {
      const ci: number | undefined = visibleAnns[i].chapterIndex;
      if (ci !== undefined && chapterSet.indexOf(ci) === -1) {
        chapterSet.push(ci);
      }
    }
    chapterSet.sort((a: number, b: number): number => a - b);
    // 构建分组
    const result: ChapterAnnotationGroup[] = [];
    for (let i: number = 0; i < chapterSet.length; i++) {
      const ci: number = chapterSet[i];
      const groupAnns: Annotation[] = [];
      for (let j: number = 0; j < visibleAnns.length; j++) {
        if (visibleAnns[j].chapterIndex === ci) {
          groupAnns.push(visibleAnns[j]);
        }
      }
      groupAnns.sort((a: Annotation, b: Annotation): number =>
        (a.startCharOffset ?? a.locator?.paragraphIndex ?? 0) -
        (b.startCharOffset ?? b.locator?.paragraphIndex ?? 0)
      );
      result.push({
        chapterIndex: ci,
        title: '第' + (ci + 1) + '章',
        annotations: groupAnns
      });
    }
    this.groups = result;
  }

  /**
   * 删除标注（侧滑触发）
   */
  private deleteAnnotation(ann: Annotation): void {
    const engine: OhEngine | undefined = _pageEngine;
    if (engine === undefined) {
      return;
    }
    // 从分组中移除
    let groupIdx: number = -1;
    for (let i: number = 0; i < this.groups.length; i++) {
      if (this.groups[i].chapterIndex === ann.chapterIndex) {
        groupIdx = i;
        break;
      }
    }
    if (groupIdx === -1) {
      return;
    }
    const group: ChapterAnnotationGroup = this.groups[groupIdx];
    let subIdx: number = -1;
    for (let i: number = 0; i < group.annotations.length; i++) {
      if (group.annotations[i].id === ann.id) {
        subIdx = i;
        break;
      }
    }
    if (subIdx === -1) {
      return;
    }
    group.annotations.splice(subIdx, 1);
    if (group.annotations.length === 0) {
      this.groups.splice(groupIdx, 1);
    } else {
      this.groups[groupIdx] = group;
    }
    // 持久化删除
    const bookId: string = engine.getPublication()?.getMetadata().title ?? '';
    engine.annotationStorage.remove(bookId, ann.id);
  }

  /**
   * 跳转到标注位置（委托 engine.goToAnnotation 执行二分查找导航）
   */
  private navigateToAnnotation(ann: Annotation): void {
    const engine: OhEngine | undefined = _pageEngine;
    if (engine === undefined) {
      return;
    }
    engine.goToAnnotation(ann);
    router.back();
  }

  // ── 构建器 ──

  @Builder
  private groupHeader(group: ChapterAnnotationGroup): void {
    Text(group.title)
      .fontSize(16)
      .fontWeight(FontWeight.Bold)
      .padding({ left: 16, top: 8, bottom: 4 });
  }

  @Builder
  private buildDeleteButton(ann: Annotation): void {
    Button() {
      Text('删除')
        .fontColor(Color.White)
        .fontSize(14);
    }
    .width(64)
    .height('100%')
    .backgroundColor(Color.Red)
    .onClick(() => {
      this.deleteAnnotation(ann);
    });
  }

  build() {
    Column() {
      if (this.groups.length === 0) {
        Text('暂无标注')
          .fontSize(16)
          .fontColor('#999999')
          .alignSelf(ItemAlign.Center)
          .margin({ top: 80 });
      } else {
        List() {
          ForEach(this.groups, (group: ChapterAnnotationGroup) => {
            ListItemGroup({ header: (): void => this.groupHeader(group) }) {
              ForEach(group.annotations, (ann: Annotation) => {
                ListItem() {
                  this.annotationCard(ann);
                }
                .swipeAction({ end: (): void => this.buildDeleteButton(ann) })
                .onClick((): void => {
                  this.navigateToAnnotation(ann);
                });
              }, (ann: Annotation): string => ann.id);
            }
          }, (group: ChapterAnnotationGroup): string => 'g' + group.chapterIndex);
        }
        .width('100%')
        .height('100%');
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5');
  }

  @Builder
  private annotationCard(ann: Annotation): void {
    Row() {
      // 颜色标记条
      Column()
        .width(4)
        .height('100%')
        .backgroundColor(ann.color ?? '#FFEB3B')
        .margin({ right: 12 });
      // 内容区域
      Column() {
        // 标注文本（最多 2 行）
        Text(ann.text ?? '')
          .fontSize(14)
          .fontColor('#333333')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(20);
        // 笔记文本（优先使用 noteText，向后兼容 note）
        let noteText: string | undefined = ann.noteText ?? ann.note;
        if (noteText !== undefined && noteText.length > 0) {
          Text(noteText)
            .fontSize(12)
            .fontColor('#888888')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 });
        }
      }
      .layoutWeight(1)
      .alignSelf(ItemAlign.Center);
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, right: 16 })
    .backgroundColor(Color.White)
    .borderRadius(8);
  }
}
