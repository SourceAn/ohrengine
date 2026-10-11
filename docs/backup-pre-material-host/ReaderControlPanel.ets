import type { Margins } from 'ohrengine-common';
import type { Theme } from 'ohrengine-feature';
import type { ReaderTextAlign } from '../utils/ReaderSettings.ets';
import { ReaderTurnMode } from '../utils/ReaderSettings.ets';
import { MaterialConfig } from '../common/MaterialConfig.ets';
import { readerIsDark, isWideScreen, screenHeightVp, screenWidthVp } from '../common/ReaderTheme.ets';
import { ControlSpec } from '../common/ControlSpec.ets';
import { ReaderScrubBar } from './ReaderScrubBar.ets';
import type { SeekInfo } from './ReaderScrubBar.ets';
import { ReaderFontSlider } from './ReaderFontSlider.ets';
import { ReaderLineSpacingSlider } from './ReaderLineSpacingSlider.ets';
import { FontPickerCard } from './FontPickerPanel.ets';
import { AlignPickerCard } from './AlignPickerPanel.ets';
import { TurnModePickerCard } from './TurnModePickerCard.ets';
import { BackgroundStrip } from './BackgroundStrip.ets';
import { IconAssets } from '../common/IconAssets.ets';

/**
 * 底部菜单栏双模式（由调用阅读引擎的一方选择，不提供应用内切换）：
 * - DEBUG：调试模式 —— 第 4 格为「设置」入口（当前正常布局）；
 * - TEST：测试模式 —— 第 4 格替换为「单手翻页」开关。
 */
export enum MenuBarMode {
  DEBUG = 'debug',
  TEST = 'test'
}

/** 统一胶囊高度以上常量… */
const SLIDER_CAPSULE_H: number = ControlSpec.ROW_H;
/** 功能胶囊统一高度（以进度条为标准） */
const FUNC_CAPSULE_H: number = ControlSpec.FUNC_CAPSULE_H;
/** 功能胶囊统一圆角（完全胶囊形，以进度条为标准） */
const CAPSULE_RADIUS: number = 24;
/** 胶囊统一内边距（滑块行） */
const ROW_PAD: number = 12;
/** 滑块行两侧固定占位宽度（箭头 / 图标），保证三根控制条长度一致 */
const SIDE_ZONE: number = 46;
/** 功能胶囊间距 */
const CAPSULE_GAP: number = 8;
/** 底部安全间距（距底部导航栏） */
const BOTTOM_SAFE: number = ControlSpec.BOTTOM_SAFE;
/** 翻页方式弹窗卡片尺寸（窄卡，浮于按钮上方） */
const TURN_CARD_W: number = 208;
const TURN_CARD_H: number = 132;
const ALIGN_CARD_H: number = 110;
/** 行5（功能胶囊行）含上下内边距行高 */
const ROW5_H: number = ControlSpec.FUNC_ROW_H;
/** 行4（功能胶囊行）含上下内边距行高 */
const ROW4_H: number = FUNC_CAPSULE_H + 6;

/**
 * 阅读器底部控制栏 — 纯悬浮胶囊式（无统一背景 / 大面积容器 / 遮罩）。
 *
 * 五行布局（自上而下）：
 * 1. 阅读进度条（左翻页 + 进度条 + 右翻页，无页码文字）
 * 2. 字号调整条（A- · 滑杆 · 拖动手柄）
 * 3. 行间距调整条（收紧 · 滑杆 · 展开抽屉）
 * 4. 字体调整 + 自动对齐方式（两个功能胶囊）
 * 5. 背景 | 对齐方式 | 自动 | 阅读设置（四个功能胶囊）
 *
 * 进度条 / 字号 / 行间距 三根控制条共享同一宽度参数（两侧占位等宽，长度统一）；
 * 所有图标为 HarmonyOS 填充图标体系，视觉重量一致；
 * 「自动」为自动播放（自动翻页）入口；「背景」展开主题色横条覆盖功能胶囊区域。
 */
@Component
export struct ReaderControlPanel {
  @Prop progress: number = 0;         // 0~1
  @Prop fontSizeLevel: number = 5;    // 1~9
  @Prop lineSpacingLevel: number = 3; // 1~5
  @Prop textAlign: ReaderTextAlign = 'justify';
  @Prop turnMode: ReaderTurnMode = ReaderTurnMode.SIMULATION;
  /** 单手模式状态（测试模式下的开关按钮控制） */
  @Prop singleHand: boolean = false;
  /** 当前字体族（字体调整入口显示） */
  currentFontFamily: string = '';
  /** 可选背景主题（背景横条色块） */
  themes: Theme[] = [];
  /** 当前主题 id（@Link 与 Index 实时双向同步） */
  @Link @Watch('onThemeIdChanged') currentThemeId: string;

  /** 面板本地深色态（@StorageProp 跟随系统深浅色，驱动图标/文字即时重绘） */
  @State localDark: boolean = false;
  @StorageProp('darkMode') @Watch('onDarkModeChanged') darkMode: boolean = false;

  /** 系统深浅色变化：同步本地深色态驱动面板重绘 */
  private onDarkModeChanged(): void {
    this.localDark = this.darkMode;
  }

  /** @Watch：外部主题变化时同步本地深色态（历史逻辑保留，当前以系统深浅色为准） */
  private onThemeIdChanged(): void {
    this.localDark = readerIsDark();
  }

  /** 主前景色：功能胶囊图标 + 文字（随深浅色自适应） */
  private mainFg(): string {
    return this.localDark ? '#E3E5E8' : '#2B2B2B';
  }

  /**
   * 控制列宽度：平板横屏限制为屏宽 1/3（居中悬浮）；
   * 手机 / 平板竖屏保持内容区全宽。
   */
  private panelWidth(): number {
    if (isWideScreen() && screenWidthVp() > screenHeightVp()) {
      return Math.min(this.contentWidth, Math.round(screenWidthVp() / 3));
    }
    return this.contentWidth;
  }

  /** 次级前景色：滑杆侧图标 / 进度箭头（随深浅色自适应） */
  private subFg(): string {
    return this.localDark ? '#AEB4BA' : '#4A4F55';
  }

  aboutToAppear(): void {
    this.localDark = readerIsDark();
  }
  /** 菜单栏模式（调用引擎时选择：调试 / 测试） */
  barMode: MenuBarMode = MenuBarMode.DEBUG;
  margins: Margins = { left: 10, right: 10, top: 50, bottom: 36 } as Margins;
  avoidAreaBottom: number = 0;
  contentWidth: number = 344;
  canvasH: number = 800;
  onProgressChange: (v: number) => void = () => {};
  onQuerySeekInfo: (v: number) => SeekInfo = (_v: number): SeekInfo => {
    return { title: '', pageNum: 0, totalPages: 0 };
  };
  onPrevPage: () => void = () => {};
  onNextPage: () => void = () => {};
  onFontSizeLevelChange: (level: number) => void = () => {};
  onLineSpacingLevelChange: (level: number) => void = () => {};
  onTextAlignChange: (align: ReaderTextAlign) => void = () => {};
  /** 翻页方式（对齐方式入口 → 翻页方式选择） */
  onTurnModeChange: (mode: ReaderTurnMode) => void = (_mode: ReaderTurnMode): void => {};
  /** 应用系统字体（Index） */
  onSelectFont: (family: string) => void = (_family: string): void => {};
  /** 选择背景主题（Index 应用主题） */
  onSelectTheme: (id: string) => void = (_id: string): void => {};
  /** 切换深色 / 明亮模式 */
  onToggleTheme: () => void = () => {};
  /** 切换单手模式开关（测试模式下由底部栏控制） */
  onSingleHandChange: (v: boolean) => void = (_v: boolean): void => {};
  onOpenSettings: () => void = () => {};

  /** 对齐 / 字体 / 翻页方式弹窗 / 主题横条（本地状态） */
  @State showAlignPicker: boolean = false;
  @State showFontPicker: boolean = false;
  @State showTurnModePicker: boolean = false;
  @State showThemeStrip: boolean = false;
  /** 菜单主体高度（弹窗定位用，onAreaChange 实测） */
  @State menuH: number = 300;

  build() {
    Stack() {
      // ═══ 底部控制列（无统一背景，独立悬浮胶囊）═══
      Column() {
        // ── 行1：阅读进度条（左翻页 · 进度条 · 右翻页，纯图标无按钮叠加） ──
        Row() {
          Row() {
            // 左侧图标 = 右侧箭头镜像（朝向相反）
            Image(IconAssets.nextPage())
              .width(20).height(20)
              .objectFit(ImageFit.Contain)
              .fillColor(this.subFg())
              .scale({ x: -1, y: 1 })
          }
          .width(SIDE_ZONE).height('100%')
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.onPrevPage();
          })
          ReaderScrubBar({
            value: this.progress,
            onQuerySeekInfo: (v: number): SeekInfo => this.onQuerySeekInfo(v),
            onCommit: (v: number): void => {
              this.onProgressChange(v);
            },
            onScrubStateChange: (_active: boolean): void => {
            }
          })
            .layoutWeight(1)
          Row() {
            Image(IconAssets.nextPage())
              .width(20).height(20)
              .objectFit(ImageFit.Contain)
              .fillColor(this.subFg())
          }
          .width(SIDE_ZONE).height('100%')
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.onNextPage();
          })
        }
        .width('100%')
        .height(SLIDER_CAPSULE_H)
        .padding({ left: ROW_PAD, right: ROW_PAD })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(MaterialConfig.menuCapsuleThemeBg(this.localDark))
        .backgroundBlurStyle(MaterialConfig.menuCapsuleThemeBlur(this.localDark))
        .systemMaterial(MaterialConfig.menuCapsuleThemeMaterial(this.localDark))
        .borderRadius(SLIDER_CAPSULE_H / 2)
        .margin({ top: 2, bottom: 2 })
        .zIndex(1)

        // ── 行2：字号调整条（A- · 滑杆 · 拖动手柄） ──
        Row() {
          Row() {
            SymbolGlyph(IconAssets.fontSmaller())
              .fontSize(16).fontColor([this.subFg()])
          }
          .width(SIDE_ZONE).justifyContent(FlexAlign.Center)
          ReaderFontSlider({
            level: Math.max(1, Math.min(9, this.fontSizeLevel)),
            onLevelCommit: (slot: number): void => {
              this.onFontSizeLevelChange(slot);
            },
            onFocusChange: (_active: boolean): void => {
            }
          })
            .layoutWeight(1)
          Row() {
            Image(IconAssets.fontDrag())
              .width(18).height(18)
              .objectFit(ImageFit.Contain)
              .fillColor(this.subFg())
          }
          .width(SIDE_ZONE).justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height(SLIDER_CAPSULE_H)
        .padding({ left: ROW_PAD, right: ROW_PAD })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(MaterialConfig.menuCapsuleThemeBg(this.localDark))
        .backgroundBlurStyle(MaterialConfig.menuCapsuleThemeBlur(this.localDark))
        .systemMaterial(MaterialConfig.menuCapsuleThemeMaterial(this.localDark))
        .borderRadius(SLIDER_CAPSULE_H / 2)
        .margin({ top: 2, bottom: 2 })
        .zIndex(2)

        // ── 行3：行间距调整条（收紧 · 滑杆 · 展开抽屉） ──
        Row() {
          Row() {
            SymbolGlyph(IconAssets.lineSpacingTight())
              .fontSize(16).fontColor([this.subFg()])
          }
          .width(SIDE_ZONE).justifyContent(FlexAlign.Center)
          ReaderLineSpacingSlider({
            level: this.lineSpacingLevel,
            onLevelCommit: (slot: number): void => {
              this.onLineSpacingLevelChange(slot);
            },
            onFocusChange: (_active: boolean): void => {
            }
          })
            .layoutWeight(1)
          Row() {
            Image(IconAssets.spacingAdjust())
              .width(18).height(18)
              .objectFit(ImageFit.Contain)
              .fillColor(this.subFg())
          }
          .width(SIDE_ZONE).justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height(SLIDER_CAPSULE_H)
        .padding({ left: ROW_PAD, right: ROW_PAD })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(MaterialConfig.menuCapsuleThemeBg(this.localDark))
        .backgroundBlurStyle(MaterialConfig.menuCapsuleThemeBlur(this.localDark))
        .systemMaterial(MaterialConfig.menuCapsuleThemeMaterial(this.localDark))
        .borderRadius(SLIDER_CAPSULE_H / 2)
        .margin({ top: 2, bottom: 2 })
        .zIndex(3)

        // ── 行4：字体调整 + 对齐方式 ──
        Row({ space: CAPSULE_GAP }) {
          this.funcGlassImageCapsule(IconAssets.font(), '字体调整', (): void => {
            this.showAlignPicker = false;
            this.showTurnModePicker = false;
            this.showThemeStrip = false;
            this.showFontPicker = !this.showFontPicker;
          })
          this.funcGlassImageCapsule(IconAssets.alignEntry(), '对齐方式', (): void => {
            this.showFontPicker = false;
            this.showTurnModePicker = false;
            this.showThemeStrip = false;
            this.showAlignPicker = !this.showAlignPicker;
          })
        }
        .width('100%')
        .padding({ top: 3, bottom: 3 })
        .zIndex(4)

        // ── 行5：背景 | 对齐方式 | 自动 | 阅读设置（或主题色展开横条） ──
        if (this.showThemeStrip) {
          BackgroundStrip({
            themes: this.themes,
            currentThemeId: this.currentThemeId,
            stripHeight: FUNC_CAPSULE_H,
            onSelectTheme: (id: string): void => {
              this.onSelectTheme(id);
            },
            onClose: (): void => {
              this.collapseThemeStrip();
            }
          })
            .width('100%')
            .padding({ top: 3, bottom: 2 })
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.translate({ x: 56 })
                .combine(TransitionEffect.opacity(0.15))
                .combine(TransitionEffect.scale({ x: 0.9 })),
              TransitionEffect.opacity(0).combine(TransitionEffect.scale({ x: 0.92 }))
            ) as TransitionEffect)
            .zIndex(5)
        } else {
          Row({ space: CAPSULE_GAP }) {
            this.funcGlassImageCapsule(IconAssets.theme(), '背景', (): void => {
              this.expandThemeStrip();
            })
            this.funcGlassTextCapsule('翻页方式', (): void => {
              // 翻页方式功能：展开翻页方式弹窗（位于按钮上方，遮住其他行）
              this.showAlignPicker = false;
              this.showFontPicker = false;
              this.showThemeStrip = false;
              this.showTurnModePicker = !this.showTurnModePicker;
            })
            Row() {
              if (this.localDark) {
                Image(IconAssets.themeDark())
                  .width(16).height(16)
                  .objectFit(ImageFit.Contain)
                  .fillColor(this.mainFg())
                Text('深色')
                  .fontSize(12).fontWeight(FontWeight.Medium)
                  .fontColor(this.mainFg())
                  .margin({ left: 5 })
                  .maxLines(1)
              } else {
                Image(IconAssets.themeLight())
                  .width(16).height(16)
                  .objectFit(ImageFit.Contain)
                  .fillColor(this.mainFg())
                Text('明亮')
                  .fontSize(12).fontWeight(FontWeight.Medium)
                  .fontColor(this.mainFg())
                  .margin({ left: 5 })
                  .maxLines(1)
              }
            }
    .layoutWeight(1)
    .height(FUNC_CAPSULE_H)
    .padding({ left: 12, right: 12 })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(MaterialConfig.topButtonBg())
    .backgroundBlurStyle(MaterialConfig.topButtonBlur())
    .systemMaterial(MaterialConfig.topButtonMaterial())
    .borderRadius(CAPSULE_RADIUS)
    .onClick(() => {
      // 先本地翻转（结构 if/else 由 @State 驱动，必然重绘图标/文字）
      this.localDark = !this.localDark;
      try {
        this.onToggleTheme();
      } catch (e) {
      }
    })
            this.funcModeSlot()
          }
          .width('100%')
          .padding({ top: 3, bottom: 2 })
          .zIndex(5)
        }
      }
      .width('100%')
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const h: number = newArea.height as number;
        if (h > 0) {
          this.menuH = h;
        }
      })
      .zIndex(1)

      // ═══ 字体弹窗（控制区正上方）═══
      if (this.showFontPicker) {
        FontPickerCard({
          cardWidth: this.panelWidth(),
          cardHeight: this.fontCardHeight(),
          currentFamily: this.currentFontFamily,
          onSelectFont: (family: string): void => {
            this.onSelectFont(family);
            this.showFontPicker = false;
          },
          onClose: (): void => {
            this.showFontPicker = false;
          }
        })
          .position({
            left: 0,
            y: 0
          })
          .zIndex(30)
      }

      // ═══ 对齐方式弹窗（长胶囊宽度，底部紧挨「对齐方式」按钮，遮住上方行）═══
      if (this.showAlignPicker) {
        AlignPickerCard({
          cardWidth: this.panelWidth(),
          cardHeight: ALIGN_CARD_H,
          current: this.textAlign,
          onSelect: (align: ReaderTextAlign): void => {
            this.onTextAlignChange(align);
            this.showAlignPicker = false;
          },
          onClose: (): void => {
            this.showAlignPicker = false;
          }
        })
          .position({
            left: 0,
            y: this.alignCardTopY()
          })
          .zIndex(31)
      }

      // ═══ 翻页方式弹窗（窄卡，位于「翻页方式」按钮上方，遮住其他行）═══
      if (this.showTurnModePicker) {
        TurnModePickerCard({
          cardWidth: Math.max(TURN_CARD_W, Math.min(Math.round(this.panelWidth() * 0.45), 320)),
          cardHeight: TURN_CARD_H,
          current: this.turnMode,
          onSelect: (mode: ReaderTurnMode): void => {
            this.onTurnModeChange(mode);
            this.showTurnModePicker = false;
          },
          onClose: (): void => {
            this.showTurnModePicker = false;
          }
        })
          .position({
            x: this.turnCardLeft(),
            y: this.turnCardTopY()
          })
          .zIndex(32)
      }
    }
    .width(this.panelWidth())
    // 悬浮式控制区：靠近底部导航栏 10px（遵守安全区 / 屏幕边界）
    .position({
      left: Math.round((screenWidthVp() - this.panelWidth()) / 2),
      bottom: this.avoidAreaBottom + BOTTOM_SAFE
    })
    .zIndex(100)
    // 目录卡弹出时菜单栏向下淡出关闭（恢复时反向淡入）
    .transition(TransitionEffect.opacity(0)
      .combine(TransitionEffect.translate({ y: 80 })) as TransitionEffect)
  }

  /** 功能胶囊（透明玻璃背景，与顶部返回按钮统一：无背景色） */
  @Builder
  funcGlassImageCapsule(icon: Resource, label: string, action: () => void) {
    Row() {
      Image(icon)
        .width(16).height(16)
        .objectFit(ImageFit.Contain)
        .fillColor(this.mainFg())
      Text(label)
        .fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(this.mainFg())
        .margin({ left: 5 })
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(FUNC_CAPSULE_H)
    .padding({ left: 12, right: 12 })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Color.Transparent)
    .systemMaterial(MaterialConfig.topButtonMaterial())
    .borderRadius(CAPSULE_RADIUS)
    .onClick(() => {
      action();
    })
  }

  /** 文字胶囊（透明玻璃背景，与顶部返回按钮统一；如对齐方式 / 翻页方式） */
  @Builder
  funcGlassTextCapsule(label: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(this.mainFg())
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(FUNC_CAPSULE_H)
    .padding({ left: 12, right: 12 })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(MaterialConfig.topButtonBg())
    .backgroundBlurStyle(MaterialConfig.topButtonBlur())
    .systemMaterial(MaterialConfig.topButtonMaterial())
    .borderRadius(CAPSULE_RADIUS)
    .onClick(() => {
      action();
    })
  }

  /**
   * 底部菜单栏第 4 个胶囊（双模式槽位，模式由调用阅读引擎时选择）：
   * - 调试模式 MenuBarMode.DEBUG：显示「设置」，点击打开阅读设置；
   * - 测试模式 MenuBarMode.TEST：显示「单手·开/关」，点击切换单手翻页模式。
   */
  @Builder
  funcModeSlot() {
    if (this.barMode === MenuBarMode.TEST) {
      Row() {
        SymbolGlyph(IconAssets.singleHand())
          .fontSize(16)
          .fontColor([this.mainFg()])
        Text(this.singleHand ? '单手·开' : '单手·关')
          .fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(this.mainFg())
          .margin({ left: 5 })
          .maxLines(1)
      }
      .layoutWeight(1)
      .height(FUNC_CAPSULE_H)
      .padding({ left: 12, right: 12 })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(MaterialConfig.topButtonBg())
      .backgroundBlurStyle(MaterialConfig.topButtonBlur())
      .systemMaterial(MaterialConfig.topButtonMaterial())
      .borderRadius(CAPSULE_RADIUS)
      .onClick(() => {
        this.onSingleHandChange(!this.singleHand);
      })
    } else {
      Row() {
        Image(IconAssets.settings())
          .width(16).height(16)
          .objectFit(ImageFit.Contain)
          .fillColor(this.mainFg())
        Text('设置')
          .fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(this.mainFg())
          .margin({ left: 5 })
          .maxLines(1)
      }
      .layoutWeight(1)
      .height(FUNC_CAPSULE_H)
      .padding({ left: 12, right: 12 })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(MaterialConfig.topButtonBg())
      .backgroundBlurStyle(MaterialConfig.topButtonBlur())
      .systemMaterial(MaterialConfig.topButtonMaterial())
      .borderRadius(CAPSULE_RADIUS)
      .onClick(() => {
        this.onOpenSettings();
      })
    }
  }

  /** 展开主题背景横条（覆盖功能胶囊区域） */
  private expandThemeStrip(): void {
    this.showAlignPicker = false;
    this.showFontPicker = false;
    this.showTurnModePicker = false;
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
      this.showThemeStrip = true;
    });
  }

  /** 收起主题背景横条（恢复功能胶囊行） */
  private collapseThemeStrip(): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.showThemeStrip = false;
    });
  }

  /** 行5（功能胶囊行）上边缘 y（弹窗定位基准） */
  private row5TopY(): number {
    return this.menuH - ROW5_H;
  }

  /** 行4（字体/对齐行）上边缘 y */
  private row4TopY(): number {
    return this.row5TopY() - ROW4_H;
  }

  /** 字体弹窗高度：顶部=进度条上部(y=0)，底部=「字体调整」胶囊上部(row4TopY) */
  private fontCardHeight(): number {
    return Math.max(120, this.row4TopY());
  }

  /** 对齐方式弹窗 top：底部紧挨「对齐方式」按钮上方（长胶囊宽度） */
  private alignCardTopY(): number {
    const y: number = this.row4TopY() - ALIGN_CARD_H - 2;
    return Math.max(0, y);
  }

  /** 翻页方式弹窗 top：底部位于「翻页方式」按钮上方，遮住其他行 */
  private turnCardTopY(): number {
    const y: number = this.row5TopY() - TURN_CARD_H - 6;
    return Math.max(0, y);
  }

  /** 翻页方式弹窗 left：水平居中于行5第2个胶囊（翻页方式） */
  private turnCardLeft(): number {
    const w: number = (this.panelWidth() - 3 * CAPSULE_GAP) / 4;
    const center: number = CAPSULE_GAP + w * 1.5;
    const maxX: number = this.panelWidth() - TURN_CARD_W;
    if (maxX <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(maxX, center - TURN_CARD_W / 2));
  }
}