import type { Margins } from 'ohrengine-common';
import { ReaderFeatureFlags } from 'ohrengine-common';
import { ReaderPageNumberMode } from '../utils/ReaderSettings.ets';
import { MaterialConfig } from '../common/MaterialConfig.ets';
import { ReaderTheme } from '../common/ReaderTheme.ets';
import { IconAssets } from '../common/IconAssets.ets';

/**
 * 阅读设置面板（沉浸光感最强）。
 * 翻页方式（仿真/横滑/上下滑动/无动效）、眼动翻页（占位）、单手模式、
 * 自动翻页与翻页速度（0.5x–1.5x）、页码显示模式、退出自动翻页，以及
 * 既有「功能」区（生词本/批注/导出/词典API设置）。
 */
@Component
export struct ReaderSettingsPanel {
  @StorageProp('darkMode') darkMode: boolean = false;
  @Prop singleHand: boolean = false;
  @Prop autoSpeed: number = 1.0;
  @Prop autoTurning: boolean = false;
  @Prop pageNumberMode: ReaderPageNumberMode = ReaderPageNumberMode.TOTAL;
  /** 阅读功能能力开关（按需隐藏批注/导出/听书等未交付能力） */
  featureFlags: ReaderFeatureFlags = ReaderFeatureFlags.allOn();
  margins: Margins = { left: 10, right: 10, top: 50, bottom: 36 } as Margins;
  avoidAreaBottom: number = 0;
  contentWidth: number = 344;
  canvasH: number = 800;
  onSingleHandChange: (v: boolean) => void = () => {};
  onAutoSpeedChange: (v: number) => void = () => {};
  onStartAutoTurn: () => void = () => {};
  onExitAutoTurn: () => void = () => {};
  onPageNumberModeChange: (mode: ReaderPageNumberMode) => void = () => {};
  onOpenVocabulary: () => void = () => {};
  onToggleAnnotationPanel: () => void = () => {};
  onExportAnnotations: () => void = () => {};
  onOpenApiConfig: () => void = () => {};
  onToggleListen: () => void = () => {};
  onClose: () => void = () => {};

  build() {
    // 半模态（bindSheet）内容：卡片铺满弹窗，遮罩/关闭由 Sheet 自身处理。
    // API26 生效约束：材质由 SheetOptions.systemMaterial 提供，外层不设 systemMaterial。
    Column() {
      Scroll() {
        Column() {
          // ── 标题栏 ──
          Row() {
            Text('阅读设置').fontSize(16).fontWeight(FontWeight.Medium).fontColor(ReaderTheme.textPrimary)
            Blank()
            Button() {
              Image(IconAssets.cancel())
                .width(16).height(16)
                .objectFit(ImageFit.Contain)
                .fillColor(ReaderTheme.textTertiary)
            }
            .width(30).height(30)
            .type(ButtonType.Capsule).backgroundColor(MaterialConfig.capsuleBg())
              .backgroundBlurStyle(MaterialConfig.capsuleBlur())
              .systemMaterial(MaterialConfig.capsuleMaterial())
              .onClick(() => {
                this.onClose();
              })
          }
          .width('100%').padding({ bottom: 10 })

          // ── 单手翻页模式（开启后点击屏幕左右两侧均为下一页；日常为左右分区翻页） ──
          Row() {
            Text('单手翻页模式').fontSize(13).fontColor(ReaderTheme.textSecondary).layoutWeight(1)
            Button(this.singleHand ? '开' : '关')
              .height(30).fontSize(13)
              .type(ButtonType.Capsule).padding({ left: 16, right: 16 })
              .fontColor(this.singleHand ? '#FFFFFF' : ReaderTheme.textSecondary)
              .backgroundColor(this.singleHand ? MaterialConfig.accent() : MaterialConfig.capsuleBg())
              .backgroundBlurStyle(MaterialConfig.capsuleBlur())
              .systemMaterial(this.singleHand ? MaterialConfig.empty() : MaterialConfig.capsuleMaterial())
              .onClick(() => {
                this.onSingleHandChange(!this.singleHand);
              })
          }
          .width('100%').padding({ top: 2, bottom: 8 })

          // ── 自动翻页 ──
          Row() {
            Text('自动翻页').fontSize(13).fontColor(ReaderTheme.textSecondary).width(72)
            if (this.autoTurning) {
              Button('已开启 · 点正文唤起控制栏')
                .height(30).fontSize(12).fontColor(MaterialConfig.accent())
                .type(ButtonType.Capsule).padding({ left: 14, right: 14 })
                .backgroundColor(MaterialConfig.capsuleBg())
                .backgroundBlurStyle(MaterialConfig.capsuleBlur())
                .systemMaterial(MaterialConfig.capsuleMaterial())
                .onClick(() => {
                  this.onClose();
                })
            } else {
              Button('开启')
                .height(30).fontSize(13).fontColor('#FFFFFF')
                .type(ButtonType.Capsule).padding({ left: 18, right: 18 }).backgroundColor(MaterialConfig.accent())
                .onClick(() => {
                  this.onStartAutoTurn();
                })
            }
          }
          .width('100%').padding({ top: 2, bottom: 4 })

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
          .width('100%').padding({ top: 4, bottom: 6 })

          // ── 页码显示模式（章节页数 / 总页数 / 进度百分比） ──
          Row({ space: 6 }) {
            Text('页码显示').fontSize(13).fontColor(ReaderTheme.textSecondary).width(72)
            Button('章节页数')
              .height(30).fontSize(12)
              .type(ButtonType.Capsule).padding({ left: 12, right: 12 })
              .fontColor(this.pageNumberMode === ReaderPageNumberMode.CHAPTER ? '#FFFFFF' : ReaderTheme.textSecondary)
              .backgroundColor(this.pageNumberMode === ReaderPageNumberMode.CHAPTER ? MaterialConfig.accent() : MaterialConfig.capsuleBg())
              .backgroundBlurStyle(MaterialConfig.capsuleBlur())
              .systemMaterial(this.pageNumberMode === ReaderPageNumberMode.CHAPTER ? MaterialConfig.empty() : MaterialConfig.capsuleMaterial())
              .onClick(() => {
                this.onPageNumberModeChange(ReaderPageNumberMode.CHAPTER);
              })
            Button('总页数')
              .height(30).fontSize(12)
              .type(ButtonType.Capsule).padding({ left: 12, right: 12 })
              .fontColor(this.pageNumberMode === ReaderPageNumberMode.TOTAL ? '#FFFFFF' : ReaderTheme.textSecondary)
              .backgroundColor(this.pageNumberMode === ReaderPageNumberMode.TOTAL ? MaterialConfig.accent() : MaterialConfig.capsuleBg())
              .backgroundBlurStyle(MaterialConfig.capsuleBlur())
              .systemMaterial(this.pageNumberMode === ReaderPageNumberMode.TOTAL ? MaterialConfig.empty() : MaterialConfig.capsuleMaterial())
              .onClick(() => {
                this.onPageNumberModeChange(ReaderPageNumberMode.TOTAL);
              })
            Button('百分比')
              .height(30).fontSize(12)
              .type(ButtonType.Capsule).padding({ left: 12, right: 12 })
              .fontColor(this.pageNumberMode === ReaderPageNumberMode.PERCENT ? '#FFFFFF' : ReaderTheme.textSecondary)
              .backgroundColor(this.pageNumberMode === ReaderPageNumberMode.PERCENT ? MaterialConfig.accent() : MaterialConfig.capsuleBg())
              .backgroundBlurStyle(MaterialConfig.capsuleBlur())
              .systemMaterial(this.pageNumberMode === ReaderPageNumberMode.PERCENT ? MaterialConfig.empty() : MaterialConfig.capsuleMaterial())
              .onClick(() => {
                this.onPageNumberModeChange(ReaderPageNumberMode.PERCENT);
              })
          }
          .width('100%').padding({ top: 4, bottom: 8 })

          // ── 退出自动翻页 ──
          if (this.autoTurning) {
            Button('退出自动翻页')
              .width('100%').height(36).fontSize(14).fontColor(ReaderTheme.danger)
              .type(ButtonType.Capsule).backgroundColor(this.darkMode ? '#26FF6B6B' : '#1CE5484D')
              .margin({ top: 2, bottom: 8 })
              .onClick(() => {
                this.onExitAutoTurn();
              })
          }

          // ── 听书（自底部菜单栏移入，可按能力开关隐藏） ──
          if (this.featureFlags.listen) {
            Row() {
              Text('听书').fontSize(13).fontColor(ReaderTheme.textSecondary).width(72)
              Button('开启 (占位)')
                .height(30).fontSize(13).fontColor(ReaderTheme.accent)
                .type(ButtonType.Capsule).padding({ left: 16, right: 16 })
                .backgroundColor(MaterialConfig.capsuleBg())
                .backgroundBlurStyle(MaterialConfig.capsuleBlur())
                .systemMaterial(MaterialConfig.capsuleMaterial())
                .onClick(() => {
                  this.onToggleListen();
                })
            }
            .width('100%').padding({ top: 2, bottom: 6 })
          }

          // ── 功能（保留既有入口；批注/导出可按能力开关隐藏） ──
          Text('功能').fontSize(13).fontColor(ReaderTheme.textTertiary).width('100%')
          Row({ space: 8 }) {
            this.funcCapsule('生词本', () => this.onOpenVocabulary())
            if (this.featureFlags.annotations) {
              this.funcCapsule('批注', () => this.onToggleAnnotationPanel())
            }
            if (this.featureFlags.exportAnnotations) {
              this.funcCapsule('导出批注', () => this.onExportAnnotations())
            }
            this.funcCapsule('词典API', () => this.onOpenApiConfig())
          }
          .width('100%').justifyContent(FlexAlign.SpaceBetween).padding({ top: 8, bottom: 4 })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 14, bottom: 14 + this.avoidAreaBottom })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%').height('100%')
    .padding({ left: this.margins.left, right: this.margins.right, top: 12, bottom: 12 })
    .backgroundColor(MaterialConfig.sheetBg())
    .backgroundBlurStyle(MaterialConfig.sheetBlur())
    .borderRadius(24)
  }

  @Builder
  funcCapsule(label: string, action: () => void) {
    Button(label)
      .height(32).fontSize(12).fontColor(ReaderTheme.textPrimary)
      .type(ButtonType.Capsule).padding({ left: 12, right: 12 })
      .backgroundColor(MaterialConfig.capsuleBg())
      .backgroundBlurStyle(MaterialConfig.capsuleBlur())
      .systemMaterial(MaterialConfig.capsuleMaterial())
      .onClick(() => {
        action();
      })
  }

  private autoSpeedLabel(): string {
    return this.autoSpeed.toFixed(1) + 'x';
  }
}
