import type { Margins } from 'ohrengine-common';
import { MaterialConfig } from '../common/MaterialConfig.ets';
import { ReaderTheme } from '../common/ReaderTheme.ets';

/**
 * 自动翻页控制栏（沉浸光感最强）。
 * 标题「自动翻页」+ 右侧「关闭控制面板」（关闭=继续自动翻页）；
 * 翻页速度独立成行（0.5x–1.5x）；退出自动翻页按钮。
 */
@Component
export struct AutoTurnBar {
  @StorageProp('darkMode') darkMode: boolean = false;
  @Prop autoSpeed: number = 1.0;
  margins: Margins = { left: 10, right: 10, top: 50, bottom: 36 } as Margins;
  avoidAreaBottom: number = 0;
  contentWidth: number = 344;
  canvasH: number = 800;
  onAutoSpeedChange: (v: number) => void = () => {};
  /** 关闭控制面板（继续自动翻页） */
  onResume: () => void = () => {};
  /** 退出自动翻页 */
  onExit: () => void = () => {};

  build() {
    Column() {
      // ── 标题 + 关闭按钮 ──
      Row() {
        Text('自动翻页').fontSize(16).fontWeight(FontWeight.Medium).fontColor(ReaderTheme.textPrimary)
        Blank()
        Button('关闭控制面板')
          .height(30).fontSize(12).fontColor(MaterialConfig.accent())
          .type(ButtonType.Capsule).padding({ left: 14, right: 14 })
          .backgroundColor(MaterialConfig.capsuleBg())
          .backgroundBlurStyle(MaterialConfig.capsuleBlur())
          .systemMaterial(MaterialConfig.capsuleMaterial())
          .onClick(() => {
            this.onResume();
          })
      }
      .width('100%').padding({ bottom: 8 })

      // ── 翻页速度（独立成行） ──
      Row() {
        Text('翻页速度').fontSize(13).fontColor(ReaderTheme.textSecondary).width(72)
        Text('0.5x').fontSize(10).fontColor(ReaderTheme.textTertiary)
        Slider({
          value: this.autoSpeed, min: 0.5, max: 1.5, step: 0.1,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .selectedColor(MaterialConfig.accent())
          .onChange((v: number, _mode: SliderChangeMode) => {
            this.onAutoSpeedChange(v);
          })
        Text(this.autoSpeedLabel())
          .fontSize(12).fontColor(MaterialConfig.accent()).width(40).textAlign(TextAlign.End)
      }
      .width('100%').padding({ top: 2, bottom: 8 })

      // ── 退出自动翻页 ──
      Button('退出自动翻页')
        .width('100%').height(36).fontSize(14).fontColor(ReaderTheme.danger)
        .type(ButtonType.Capsule).backgroundColor(this.darkMode ? '#26FF6B6B' : '#1CE5484D')
        .onClick(() => {
          this.onExit();
        })
    }
    .width(this.contentWidth)
    .padding({ left: 18, right: 18, top: 14, bottom: 14 + this.avoidAreaBottom })
    .backgroundColor(MaterialConfig.floatingBarBg())
    .backgroundBlurStyle(MaterialConfig.floatingBarBlur())
    .systemMaterial(MaterialConfig.floatingBarMaterial())
    .borderRadius(28)
    .position({ left: this.margins.left, bottom: this.avoidAreaBottom + 12 })
    .transition(TransitionEffect.translate({ y: 200 }) as TransitionEffect)
    .zIndex(102)
  }

  private autoSpeedLabel(): string {
    return this.autoSpeed.toFixed(1) + 'x';
  }
}
