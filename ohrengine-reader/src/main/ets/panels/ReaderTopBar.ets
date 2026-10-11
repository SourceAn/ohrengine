import type { Margins } from 'ohrengine-common';
import { uiMaterial } from '@kit.ArkUI';
import { IconAssets } from '../common/IconAssets.ets';
import { OhGlass } from '../glass/OhGlass.ets';
import { GlassIds } from '../glass/GlassIds.ets';

/**
 * 顶部控制栏（返回 + 目录按钮）— 液态玻璃（OhGlass）。
 *
 * 结构约束（见 OHLiquidGlass/harmony/INTEGRATION.md）：
 *   · 组件背景必须透明（'#00000000'），玻璃由页面底部的 OhGlassSurface 绘制；
 *   · 必须显式关掉系统材质 .systemMaterial(uiMaterial.Material.empty)；
 *   · 组件只需 .id(GlassIds.xxx)，矩形由引擎统一解算；
 *   · .onTouch 转发给 OhGlass.touch 获得凝胶形变（可选）。
 *
 * 两个 46×46 圆钮登记为 CAPSULE（半径 = 高度一半），由 ReaderHost 登记。
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

  /** 标题栏高度：容纳安全区 + 46pt 圆钮（顶部内边距 10） */
  private titleH(): number {
    return this.avoidAreaTopVp + 66;
  }

  /** Navigation 自定义标题栏内容：两个独立玻璃圆钮 */
  @Builder
  titleBar() {
    Stack() {
      // 返回按钮（图标颜色按深浅色结构分支）
      Column() {
        if (this.isDark) {
          Image(IconAssets.back())
            .width(22).height(22)
            .objectFit(ImageFit.Contain)
            .fillColor('#FFFFFF')
        } else {
          Image(IconAssets.back())
            .width(22).height(22)
            .objectFit(ImageFit.Contain)
            .fillColor('#4A4F55')
        }
      }
      .width(46).height(46)
      .borderRadius(23)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .id(GlassIds.TOP_BACK)
      .backgroundColor('#00000000')
      .systemMaterial(uiMaterial.Material.empty)
      .position({ x: this.margins.left, y: this.avoidAreaTopVp + 10 })
      .onTouch((ev: TouchEvent): void => {
        OhGlass.touch(ev, GlassIds.TOP_BACK);
      })
      .onClick(() => {
        this.onBack();
      })

      // 目录按钮（图标颜色按深浅色结构分支）
      Column() {
        if (this.isDark) {
          Image(IconAssets.toc())
            .width(22).height(22)
            .objectFit(ImageFit.Contain)
            .fillColor('#FFFFFF')
        } else {
          Image(IconAssets.toc())
            .width(22).height(22)
            .objectFit(ImageFit.Contain)
            .fillColor('#4A4F55')
        }
      }
      .width(46).height(46)
      .borderRadius(23)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .id(GlassIds.TOP_TOC)
      .backgroundColor('#00000000')
      .systemMaterial(uiMaterial.Material.empty)
      .position({ x: this.margins.left + this.contentWidth - 46, y: this.avoidAreaTopVp + 10 })
      .onTouch((ev: TouchEvent): void => {
        OhGlass.touch(ev, GlassIds.TOP_TOC);
      })
      .onClick(() => {
        this.onToggleToc();
      })
    }
    .width('100%')
    .height(this.titleH())
  }

  build() {
    // 仅顶部标题栏高度承载沉浸光感，其余区域穿透到下方阅读画布（否则会吞掉中间点击）
    Stack({ alignContent: Alignment.Top }) {
      Navigation() {
        Column() {
        }
        .width('100%').height('100%')
      }
      .title({ builder: this.titleBar, height: this.titleH() },
        { barStyle: BarStyle.STACK, backgroundColor: Color.Transparent })
      .titleMode(NavigationTitleMode.Full)
      .hideToolBar(true)
      .mode(NavigationMode.Stack)
      .backgroundColor(Color.Transparent)
      .width('100%')
      .height(this.titleH())
    }
    .width('100%')
    .height('100%')
    // 仅两个按钮响应触摸，其余区域穿透到下方阅读画布（保留阅读区轻触翻页）
    .hitTestBehavior(HitTestMode.None)
    .onClick(() => {
      this.onTapOutside();
    })
    .transition(TransitionEffect.opacity(0)
      .combine(TransitionEffect.translate({ y: -36 })) as TransitionEffect)
  }
}
