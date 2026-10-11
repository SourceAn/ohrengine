import type { Theme } from 'ohrengine-feature';
import { MaterialConfig } from '../common/MaterialConfig.ets';
import { IconAssets } from '../common/IconAssets.ets';
import { ReaderTheme } from '../common/ReaderTheme.ets';

/**
 * 主题背景横条（点击「主题背景」入口后覆盖功能胶囊区域展开的长条胶囊）。
 *
 * - 横向瀑布流展示可选背景色圆形色块，支持横向滑动；
 * - 胶囊整体使用与功能胶囊一致的沉浸光感材质；
 * - 点击圆形色块即切换背景主题；右侧提供收起按钮恢复入口胶囊行。
 */
@Component
export struct BackgroundStrip {
  /** 可选主题（来自 PRESET_THEMES） */
  themes: Theme[] = [];
  /** 当前主题 id（选中态描边，随主题实时同步） */
  @Prop currentThemeId: string = 'day';
  /** 横条高度（与功能胶囊同高） */
  stripHeight: number = 42;
  /** 选择背景主题 */
  onSelectTheme: (id: string) => void = (_id: string): void => {};
  /** 收起横条（恢复功能胶囊行） */
  onClose: () => void = () => {};

  build() {
    Row() {
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.themes, (t: Theme) => {
            Circle()
              .width(26).height(26)
              .fill(t.backgroundColor)
              .stroke(this.currentThemeId === t.id ? ReaderTheme.accent : '#22000000')
              .strokeWidth(this.currentThemeId === t.id ? 3 : 1)
              .onClick(() => {
                this.onSelectTheme(t.id);
              })
          }, (t: Theme): string => t.id)
        }
        .height(this.stripHeight)
        .padding({ left: 12, right: 8 })
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .height(this.stripHeight)

      Button() {
        Image(IconAssets.closeFilled())
          .width(24).height(24)
          .objectFit(ImageFit.Contain)
          .fillColor(ReaderTheme.textTertiary)
      }
      .width(28).height(28)
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .margin({ right: 6 })
      .onClick(() => {
        this.onClose();
      })
    }
    .width('100%')
    .height(this.stripHeight)
    .alignItems(VerticalAlign.Center)
    .clip(true)
    .backgroundColor(MaterialConfig.menuCapsuleBgColor())
    .backgroundBlurStyle(MaterialConfig.menuCapsuleBlurStyle())
    .systemMaterial(MaterialConfig.menuCapsuleMaterial())
    .borderRadius(this.stripHeight / 2)
  }
}