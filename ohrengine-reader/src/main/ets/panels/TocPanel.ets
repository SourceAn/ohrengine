import type { TocItem } from 'ohrengine-common';
import type { Annotation } from 'ohrengine-common';
import type { Margins } from 'ohrengine-common';
import { curves } from '@kit.ArkUI';
import { MaterialConfig } from '../common/MaterialConfig.ets';
import { IconAssets } from '../common/IconAssets.ets';

/** 切换胶囊高度 */
const PILL_HEIGHT: number = 40;
/** 切换胶囊内边距（高亮胶囊相对胶囊底的内缩量） */
const PILL_PADDING: number = 4;
/** 书籍封面规格（竖向 2:3） */
const COVER_W: number = 58;
const COVER_H: number = 82;
/** 目录行高度（紧凑，减少文字上方留白） */
const ROW_HEIGHT: number = 40;
/** 目录行圆角 */
const ROW_RADIUS: number = 11;
/** 笔记行高度（标题+预览两行） */
const NOTE_ROW_HEIGHT: number = 58;
/** 书签图标规格 */
const BOOKMARK_ICON: number = 15;

/**
 * 目录 / 笔记 卡片（纯白卡片，从顶部目录按钮下方弹出）。
 *
 * - 卡片宽度与底部菜单栏一致（contentWidth），顶部从目录按钮原位置弹出，
 *   底部与阅读内容区底部对齐；顶部 8px 处为长条胶囊切换栏（[目录] [笔记]），
 *   选中高亮胶囊滑动过渡；
 * - 内容区横向滑动切换（目录离场 / 笔记进场），无闪烁跳变；
 * - 目录行紧凑排列：章节名 + 右对齐页码 + 书签图标（无书签留空）。
 */
@CustomDialog
export struct TocPanel {
  /** CustomDialogController 自动注入的控制器（@CustomDialog 必需成员） */
  controller: CustomDialogController;
  toc: TocItem[] = [];
  /** 有书签的章节索引集合 */
  bookmarkChapters: Set<number> = new Set();
  /** 有笔记/标注的章节索引集合 */
  noteChapters: Set<number> = new Set();
  /** 笔记列表（笔记分类展示） */
  notes: Annotation[] = [];
  /** 与 toc 平行的章节索引（TocItem → 引擎 getCurrentChapterIndex 语义） */
  tocChapterIndices: number[] = [];
  /** 与 toc 平行的章节起始全局页码（无法定位为 -1） */
  pageNumbers: number[] = [];
  /** 当前全局页号（当前章节行同步阅读页码） */
  currentPageNum: number = 0;
  /** 书籍标题（封面行文案） */
  bookTitle: string = '';
  /** 书籍封面绝对路径（无封面为空串，展示占位） */
  coverPath: string = '';
  isCurrent: (item: TocItem) => boolean = () => false;
  currentChapterIndex: number = -1;
  avoidAreaTopVp: number = 0;
  avoidAreaBottom: number = 0;
  contentWidth: number = 344;
  canvasH: number = 800;
  margins: Margins = { left: 10, right: 10, top: 50, bottom: 36 } as Margins;
  onClose: () => void = () => {};
  onSelect: (item: TocItem) => void = () => {};
  /** 点击笔记（定位到对应章节） */
  onSelectAnnotation: (ann: Annotation) => void = () => {};
  /** 是否为暗色主题（false=明亮：卡片 90% 雪白、深色文字） */
  isDark: boolean = false;

  @State activeTab: number = 0; // 0=目录 1=笔记

  build() {
    // 自定义弹窗（CustomDialog）内容：居中卡片，宽度沿用内容区宽，
    // 高度取屏幕可用高度 72%；材质由 CustomDialogController.systemMaterial 提供，
    // 外层不设置 systemMaterial（弹窗外层容器材质不生效）。
    Column() {
      // 行1：右上角 API26 沉浸光感关闭按钮（ic_public_cancel_filled）
      Row() {
        Button() {
          Image(IconAssets.cancel())
            .width(16).height(16)
            .objectFit(ImageFit.Contain)
            .fillColor(this.isDark ? '#D5D9DE' : '#8A8A8E')
        }
        .width(40).height(40)
        .type(ButtonType.Circle)
        .backgroundColor(MaterialConfig.capsuleBg())
        .backgroundBlurStyle(MaterialConfig.capsuleBlur())
        .systemMaterial(MaterialConfig.capsuleMaterial())
        .onClick(() => {
          this.onClose();
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ top: 6, right: 12 })

      // 行2：书籍封面 + 书名
      Row({ space: 12 }) {
        Stack() {
          Column() {
            Text('📖').fontSize(24)
          }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
          if (this.coverPath.length > 0) {
            Image('file://' + this.coverPath)
              .width('100%').height('100%')
              .objectFit(ImageFit.Cover)
              .borderRadius(8)
          }
        }
        .width(COVER_W).height(COVER_H)
        .backgroundColor(this.isDark ? '#FF333339' : '#EEEEF0')
        .borderRadius(8)
        Text(this.bookTitle)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#FFFFFF' : '#1A1A1A')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // 封面左边距与目录章节文字起点（scroll padding 10 + 行 padding 13）垂直对齐
      .padding({ left: 23, right: 14, top: 10 })

      // 行3：目录 / 笔记切换胶囊（白色沉浸光感），紧挨章节列表
      Row() {
        Stack({ alignContent: Alignment.TopStart }) {
          // 共享胶囊背景：白色 + API26 沉浸光感材质
          Row() { }.width(this.pillWidth()).height(PILL_HEIGHT)
            .backgroundColor(this.isDark ? '#FF303036' : '#E9E9EC')
            .border({ width: 1, color: this.isDark ? '#FF45454C' : '#D8D8DC' })
            .borderRadius(PILL_HEIGHT / 2)
            .systemMaterial(MaterialConfig.capsuleMaterial())
          // 选中高亮胶囊：白色按钮 + 沉浸光感（水平滑动弹性动画；垂直居中）
          Row() { }.width(this.slotWidth()).height(this.slotHeight())
            .backgroundColor(this.isDark ? '#FF414148' : '#FFFFFF')
            .border({ width: 1, color: this.isDark ? '#FF4C4C54' : '#E5E5E8' })
            .borderRadius(this.slotHeight() / 2)
            .systemMaterial(MaterialConfig.capsuleMaterial())
            .translate({ x: this.pillIndicatorX(), y: PILL_PADDING })
            .shadow({ radius: 8, color: '#33000000' })
          // 选项文字
          Row() {
            Text('目录')
              .fontSize(14)
              .fontWeight(this.activeTab === 0 ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.isDark ? (this.activeTab === 0 ? '#FFFFFF' : '#B4BAC1') : (this.activeTab === 0 ? '#1A1A1A' : '#9AA0A8'))
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .onClick(() => {
                this.switchTab(0);
              })
            Text('笔记')
              .fontSize(14)
              .fontWeight(this.activeTab === 1 ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.isDark ? (this.activeTab === 1 ? '#FFFFFF' : '#B4BAC1') : (this.activeTab === 1 ? '#1A1A1A' : '#9AA0A8'))
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .onClick(() => {
                this.switchTab(1);
              })
          }
          .width(this.pillWidth()).height(PILL_HEIGHT)
          .padding({ left: PILL_PADDING, right: PILL_PADDING })
        }
        .width(this.pillWidth()).height(PILL_HEIGHT)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 8 })

      // 内容：横向滑动轨道（目录 / 笔记）
      // 轨道宽度为卡片两倍，必须 Start 对齐，否则超宽轨道被居中导致
      // 可视窗口切到「目录右半 + 笔记左半」。
      Column() {
        Row() {
          this.tocPage()
          this.notesPage()
        }
        .width(this.cardWidth() * 2)
        .height('100%')
        .translate({ x: this.trackOffsetX() })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .clip(true)
      .layoutWeight(1)
      // 列表上边界与切换胶囊紧挨（4px）
      .padding({ top: 4, bottom: 10 })
    }
    .width(this.cardWidth())
    .height(Math.min(600, Math.max(360, this.canvasH * 0.72)))
    // 白色卡片 95% 不透明度
    .backgroundColor(this.isDark ? '#FF26262B' : 'rgba(255,255,255,0.92)')
    .borderRadius(22)
    .shadow({ radius: 24, color: '#26000000' })
  }

  /** 目录页（固定高度内部滚动，行紧凑 + 页码右对齐 + 书签图标） */
  @Builder
  tocPage() {
    Column() {
      if (this.toc.length === 0) {
        Column({ space: 6 }) {
          Text('目录为空').fontSize(13).fontColor('#9AA0A8')
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.toc, (item: TocItem, idx: number) => {
              Row({ space: 8 }) {
                Text(item.title)
                  .fontSize(15)
                   .fontColor(this.isCurrent(item) ? MaterialConfig.accent() : (this.isDark ? '#FFFFFF' : '#1A1A1A'))
                  .fontWeight(this.isCurrent(item) ? FontWeight.Medium : FontWeight.Normal)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                // 尾部右对齐组：书签图标（页码左侧） + 页码
                Row({ space: 5 }) {
                  Row() {
                    if (this.bookmarkChapters.has(this.chapterIndexOf(idx))) {
                      Image(IconAssets.bookmark())
                        .width(BOOKMARK_ICON).height(BOOKMARK_ICON)
                        .objectFit(ImageFit.Contain)
                        .fillColor('#E8A33D')
                    }
                  }
                  .width(17).height(20).justifyContent(FlexAlign.Center)
                  Text(this.rowPageNumber(idx))
                    .fontSize(12)
                    .fontColor(this.isCurrent(item) ? MaterialConfig.accent() : (this.isDark ? '#AAB1B8' : '#8A8A8E'))
                    .width(40)
                    .textAlign(TextAlign.End)
                }
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .height(ROW_HEIGHT)
              .padding({ left: 13, right: 13 })
              .borderRadius(ROW_RADIUS)
              .backgroundColor(this.isCurrent(item) ? '#262679E8' : Color.Transparent)
              .onClick(() => {
                this.onSelect(item);
              })
            }, (item: TocItem, idx: number) => (item.href ?? '') + '_' + idx)
          }
          .width('100%')
          .padding({ left: 10, right: 10, bottom: 12 })
        }
        .width('100%').height('100%').scrollBar(BarState.Off)
        // 越界弹性回弹：列表滑动不僵硬
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width(this.cardWidth()).height('100%')
  }

  /** 笔记页（标题 + 预览 + 书签图标） */
  @Builder
  notesPage() {
    Column() {
      if (this.notes.length === 0) {
        Column({ space: 8 }) {
          Text('✎').fontSize(30).fontColor('#C0C6CD')
          Text('暂无笔记，长按正文可添加').fontSize(13).fontColor('#9AA0A8')
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.notes, (ann: Annotation, idx: number) => {
              Row({ space: 8 }) {
                Column({ space: 4 }) {
                  Text(this.noteTitle(ann))
                    .fontSize(15).fontColor(this.isDark ? '#FFFFFF' : '#1A1A1A')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text((ann.text ?? ''))
                    .fontSize(12).fontColor(this.isDark ? '#A5ABB2' : '#8A8A8E')
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Row() {
                  if (this.bookmarkChapters.has(ann.chapterIndex ?? -1)) {
                    Image(IconAssets.bookmark())
                      .width(BOOKMARK_ICON).height(BOOKMARK_ICON)
                      .objectFit(ImageFit.Contain)
                      .fillColor('#E8A33D')
                  }
                }
                .width(20).height(20).justifyContent(FlexAlign.Center)
              }
              .width('100%')
              .height(NOTE_ROW_HEIGHT)
              .padding({ left: 13, right: 13 })
              .borderRadius(ROW_RADIUS)
              .onClick(() => {
                this.onSelectAnnotation(ann);
              })
            }, (ann: Annotation, idx: number) => ann.id + '_' + idx)
          }
          .width('100%')
          .padding({ left: 10, right: 10, bottom: 12 })
        }
        .width('100%').height('100%').scrollBar(BarState.Off)
        // 越界弹性回弹：笔记列表滑动不僵硬
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width(this.cardWidth()).height('100%')
  }

  /** 卡片宽度 = 底部菜单栏整体宽度 */
  private cardWidth(): number {
    return this.contentWidth;
  }

  /** 切换胶囊宽度（水平居中于卡片） */
  private pillWidth(): number {
    return Math.min(240, this.cardWidth() - 48);
  }

  /** 高亮胶囊宽度（单个选项） */
  private slotWidth(): number {
    return (this.pillWidth() - PILL_PADDING * 2) / 2;
  }

  private slotHeight(): number {
    return PILL_HEIGHT - PILL_PADDING * 2;
  }

  /** 高亮胶囊横向偏移（滑动动画） */
  private pillIndicatorX(): number {
    return PILL_PADDING + this.activeTab * this.slotWidth();
  }

  /** 内容轨道横向偏移（目录/笔记滑动切换） */
  private trackOffsetX(): number {
    return -this.activeTab * this.cardWidth();
  }

  /** 切换目录 / 笔记：高亮胶囊 + 内容弹性滑动（自然回弹，禁用瞬间切换） */
  private switchTab(tab: number): void {
    if (this.activeTab === tab) {
      return;
    }
    this.getUIContext().animateTo({
      duration: 380,
      curve: curves.springMotion(0.42, 0.58)
    }, () => {
      this.activeTab = tab;
    });
  }

  /** 章节行页码：当前章节显示实时页码，其余章节显示起始页码 */
  private rowPageNumber(idx: number): string {
    if (this.isCurrentItemAt(idx)) {
      return String(this.currentPageNum);
    }
    if (idx < this.pageNumbers.length && this.pageNumbers[idx] > 0) {
      return String(this.pageNumbers[idx]);
    }
    return '';
  }

  private isCurrentItemAt(idx: number): boolean {
    const item: TocItem | undefined = this.toc[idx];
    return item !== undefined && this.isCurrent(item);
  }

  /** 目录项对应章节索引（优先取预计算数组，回退 URL 尾段解析） */
  private chapterIndexOf(idx: number): number {
    if (idx < this.tocChapterIndices.length) {
      return this.tocChapterIndices[idx];
    }
    const item: TocItem | undefined = this.toc[idx];
    if (item === undefined) {
      return -1;
    }
    const href: string = (item.href ?? '').split('#')[0];
    const m: RegExpExecArray | null = /(\d+)\s*$/.exec(href);
    return m !== null ? parseInt(m[1], 10) - 1 : -1;
  }

  private noteTitle(ann: Annotation): string {
    if (ann.note !== undefined && ann.note.length > 0) {
      return '笔记：' + ann.note;
    }
    return '第 ' + String((ann.chapterIndex ?? 0) + 1) + ' 章';
  }
}