import type { SelectionRange } from 'ohrengine-feature';
import type { Margins } from 'ohrengine-common';
import { MaterialConfig } from '../common/MaterialConfig.ets';
import { ReaderTheme } from '../common/ReaderTheme.ets';

/**
 * 内容区长按弹窗（沉浸光感）。
 * 固定选项：复制 / 笔记 / 划线 / 高亮；
 * 条件选项：翻译（选中文本非系统语言时）、词典（选中词时）、分享（总是）。
 */
@Component
export struct SelectionContextMenu {
  @Prop selection: SelectionRange | null = null;
  /** 是否显示翻译（选中文本非系统语言） */
  @Prop showTranslate: boolean = false;
  /** 是否显示词典（选中为单个词） */
  @Prop showDictionary: boolean = false;
  /** 是否允许批注（笔记/划线/高亮）入口（能力开关裁剪） */
  @Prop annotationsEnabled: boolean = true;
  /** 菜单锚点（屏幕 vp；选中区上方） */
  @Prop anchorX: number = 0;
  @Prop anchorY: number = 0;
  margins: Margins = { left: 10, right: 10, top: 50, bottom: 36 } as Margins;
  canvasW: number = 360;
  canvasH: number = 800;
  onCopy: (text: string) => void = () => {};
  onNote: (text: string) => void = () => {};
  onUnderline: () => void = () => {};
  onTranslate: (text: string) => void = () => {};
  onDictionary: (text: string) => void = () => {};
  onShare: (text: string) => void = () => {};
  onHighlight: () => void = () => {};

  static isSingleWord(text: string): boolean {
    return text.length > 0 && !text.includes(' ') && !text.includes('\t') && !text.includes('\n');
  }

  build() {
    Stack() {
      Scroll() {
        Row({ space: 6 }) {
          this.actionButton('复制', () => {
            this.onCopy(this.selection!.text);
          })
          if (this.annotationsEnabled) {
            this.actionButton('笔记', () => {
              this.onNote(this.selection!.text);
            })
            this.actionButton('划线', () => {
              this.onUnderline();
            })
            this.actionButton('高亮', () => {
              this.onHighlight();
            }, '#FFB800')
          }
          if (this.showTranslate) {
            this.actionButton('翻译', () => {
              this.onTranslate(this.selection!.text);
            }, '#0E9F6E')
          }
          if (this.showDictionary) {
            this.actionButton('词典', () => {
              this.onDictionary(this.selection!.text);
            }, '#8B5CF6')
          }
          this.actionButton('分享', () => {
            this.onShare(this.selection!.text);
          })
        }
        .padding({ left: 6, right: 6, top: 6, bottom: 6 })
      }
      .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      .width(this.menuWidth())
      .height(48)
      .backgroundColor(MaterialConfig.cardBg())
      .backgroundBlurStyle(MaterialConfig.cardBlur())
      .systemMaterial(MaterialConfig.cardMaterial())
      .borderRadius(22)
      .position({
        x: this.clampX(this.anchorX),
        y: this.clampY(this.anchorY)
      })
      .zIndex(300)
    }
    .width('100%').height('100%')
  }

  @Builder
  actionButton(label: string, action: () => void, color: string = ReaderTheme.accent) {
    Button(label)
      .height(34).fontSize(13)
      .type(ButtonType.Capsule).padding({ left: 14, right: 14 })
      .fontColor('#FFFFFF')
      .backgroundColor(color)
      .shadow({ radius: 8, color: '#332679E8' })
      .onClick(() => {
        action();
      })
  }

  /** 菜单框宽：内容自适应，上限 330（防横屏过宽），不超过画布 92% */
  private menuWidth(): number {
    const contentW: number = this.buttonCount() * 56 + 18;
    const cap: number = Math.min(330, this.canvasW * 0.92);
    return Math.min(cap, Math.max(contentW, 150));
  }

  /** 当前按钮数（固定 5 + 条件 2） */
  private buttonCount(): number {
    let count: number = 5;
    if (this.showTranslate) {
      count++;
    }
    if (this.showDictionary) {
      count++;
    }
    return count;
  }

  private clampX(x: number): number {
    const minX: number = 8;
    const maxX: number = Math.max(minX, this.canvasW - this.menuWidth() - 8);
    return Math.min(Math.max(x, minX), maxX);
  }

  private clampY(y: number): number {
    // 菜单高约 48 + 上下留白；避免超出顶部/底部
    const minY: number = 64;
    const maxY: number = Math.max(minY, this.canvasH - 64 - 60);
    return Math.min(Math.max(y, minY), maxY);
  }
}
