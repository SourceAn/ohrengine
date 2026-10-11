import type { Margins } from 'ohrengine-common';
import { MaterialConfig } from '../common/MaterialConfig.ets';
import { IconAssets } from '../common/IconAssets.ets';

/**
 * 顶部控制栏（返回 + 目录按钮）— 沉浸光感最强档。
 *
 * - 两个圆形玻璃按钮，背景完全透明并透射页面环境色；
 * - systemMaterial（ImmersiveStyle.ULTRA_THIN）自带高光边缘、柔和阴影与半透明层次；
 * - 按钮图标随深浅色模式自适应（isDark 结构分支驱动，保证即时重绘）。
 */
@Component
export struct ReaderTopBar {
  /** 是否深色模式（跟随阅读主题） */
  @Prop isDark: boolean = false;
  margins: Margins = { left: 10, right: 10, top: 50, bottom: 36 } as Margins;
  avoidAreaTopVp: number = 0;
  contentWidth: number = 344;
  onBack: () => void = () => {};
  onToggleToc: () => void = () => {};
  /** 空白区域点击回调：容器全屏(100%x100%)，不加处理会吞掉兄弟组件触摸 */
  onTapOutside: () => void = () => {};

  build() {
    Stack() {
      // 返回按钮（图标颜色按深浅色结构分支）
      Button() {
        if (this.isDark) {
          Image(IconAssets.back())
            .width(22).height(22)
            .objectFit(ImageFit.Contain)
            .fillColor('#E6E8EB')
        } else {
          Image(IconAssets.back())
            .width(22).height(22)
            .objectFit(ImageFit.Contain)
            .fillColor('#4A4F55')
        }
      }
      .width(46).height(46)
      .type(ButtonType.Circle)
      .backgroundColor(MaterialConfig.topButtonBg())
      .backgroundBlurStyle(MaterialConfig.topButtonBlur())
      .systemMaterial(MaterialConfig.topButtonMaterial())
      .position({ x: this.margins.left, y: this.avoidAreaTopVp + 10 })
      .onClick(() => {
        this.onBack();
      })
      .zIndex(106)

      // 目录按钮（图标颜色按深浅色结构分支）
      Button() {
        if (this.isDark) {
          Image(IconAssets.toc())
            .width(22).height(22)
            .objectFit(ImageFit.Contain)
            .fillColor('#E6E8EB')
        } else {
          Image(IconAssets.toc())
            .width(22).height(22)
            .objectFit(ImageFit.Contain)
            .fillColor('#4A4F55')
        }
      }
      .width(46).height(46)
      .type(ButtonType.Circle)
      .backgroundColor(MaterialConfig.topButtonBg())
      .backgroundBlurStyle(MaterialConfig.topButtonBlur())
      .systemMaterial(MaterialConfig.topButtonMaterial())
      .position({ x: this.margins.left + this.contentWidth - 46, y: this.avoidAreaTopVp + 10 })
      .onClick(() => {
        this.onToggleToc();
      })
      .zIndex(106)
    }
    .width('100%').height('100%')
    .onClick(() => {
      this.onTapOutside();
    })
    .transition(TransitionEffect.opacity(0)
      .combine(TransitionEffect.translate({ y: -36 })) as TransitionEffect)
  }
}