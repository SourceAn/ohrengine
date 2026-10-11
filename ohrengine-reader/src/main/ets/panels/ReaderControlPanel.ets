/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * ReaderControlPanel — 底部控制栏 + 四面板半模态（设计稿 v2）
 *
 * 设计稿（阅读控制栏 · 设计提示词）落地版：
 *   · 底部 120pt 控制栏：两行（进度行 + 按钮行）共用一个液态玻璃面板（OhGlass）
 *   · 进度行：左右翻页箭头 + ReaderScrubBar（SliderStyle 自定义轨道）
 *   · 按钮行 4 入口：背景 · 排版 · 翻页 · 更多设置
 *   · 4 入口共用一个 @Builder，bindSheet 280pt 半模态（SheetSize.FIT_CONTENT）
 *   · 每面板 3 行：行模板 = 标签 13pt 左 / 控件 240pt 右；行高 40 / 行距 12
 *   · 控件：ChipGroup(单选胶囊) + Slider + Toggle
 *   · 主题令牌：浅 bg #FFFFFF / 文 #1D1D1F / 轨 #E3DFD6 / 次 #86868B；
 *             深 bg #161617 / 文 #C9C9C7 / 轨 #3A3A3C / 次 #7A7A7A
 *
 * 液态玻璃（OhGlass · 见 OHLiquidGlass/harmony/INTEGRATION.md）：
 *   · 两行（进度行 + 按钮行）共用一个玻璃面板，面板本身透明，
 *     玻璃由页面底部唯一的全屏 OhGlassSurface 绘制（矩形按 .id 解算）；
 *   · 不再需要 bgContent 自绘镜像：背景内容（画布 / 底部 scrim / 状态条）
 *     在 ReaderHost 中作为被截图层，玻璃直接透出。
 */

import type { Margins } from 'ohrengine-common';
import type { Theme } from 'ohrengine-feature';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import type { ReaderTextAlign } from '../utils/ReaderSettings.ets';
import { ReaderTurnMode, FONT_SIZE_LEVELS, LINE_SPACING_PRESETS, LINE_SPACING_LEVELS } from '../utils/ReaderSettings.ets';
import { readerIsDark } from '../common/ReaderTheme.ets';
import { ControlSpec } from '../common/ControlSpec.ets';
import { MaterialConfig } from '../common/MaterialConfig.ets';
import { IconAssets } from '../common/IconAssets.ets';
import { OhGlass } from '../glass/OhGlass.ets';
import { GlassIds } from '../glass/GlassIds.ets';
import { ReaderScrubBar } from './ReaderScrubBar.ets';
import type { SeekInfo } from './ReaderScrubBar.ets';

/* ────────────────────────────────────────────────────────────────────────────
 * MenuBarMode 保留兼容（旧的 DEBUG/TEST 模式仍可读取，未在 v2 重构中使用）
 * ──────────────────────────────────────────────────────────────────────────── */
export enum MenuBarMode {
  DEBUG = 'debug',
  TEST = 'test'
}

/* ────────────────────────────────────────────────────────────────────────────
 * QuickPanelKind — 四个面板分类枚举（设计稿"四个入口共用一个 @Builder"）
 * ──────────────────────────────────────────────────────────────────────────── */
enum QuickPanelKind {
  BACKGROUND = 'background',
  PAGE_TURN = 'page-turn',
  TYPOGRAPHY = 'typography',
  MORE = 'more'
}

/** 字体选项结构（设计稿：系统默认 / 思源宋体 / 思源黑体 / 霞鹜文楷）。 */
interface FontPreset {
  name: string;
  family: string;
}

/** 字体四选一预设。
 *  family 名若系统未安装，engine applyFontFamily 会回退默认渲染，不会崩。 */
const FONT_PRESETS: FontPreset[] = [
  { name: '系统默认', family: 'sans-serif' },
  { name: '思源宋体', family: 'Source Han Serif SC' },
  { name: '思源黑体', family: 'Source Han Sans SC' },
  { name: '霞鹜文楷', family: 'LXGW WenKai' }
];

/* 进度条胶囊（恢复备份原版布局参数） */
const SLIDER_CAPSULE_H: number = ControlSpec.ROW_H;
const ROW_PAD: number = 12;
const SIDE_ZONE: number = 46;

/* 液态玻璃面板几何：两行（进度行 + 按钮行）共用一个玻璃面板 */
const GLASS_ROW_H: number = SLIDER_CAPSULE_H + 8;
const GLASS_GAP: number = 8;
const GLASS_PANEL_H: number = GLASS_ROW_H * 2 + GLASS_GAP;
/** 玻璃面板圆角（vp），需与 ReaderHost 的 OhGlass.register 值一致 */
export const BOTTOM_BAR_RADIUS_VP: number = 20;

/* ────────────────────────────────────────────────────────────────────────────
 * ControlTokens — 设计稿主题令牌（浅/深两套，含底栏、面板、scrim 终色、轨道）
 * ──────────────────────────────────────────────────────────────────────────── */
class ControlTokens {
  static get bg(): string {
    return readerIsDark() ? '#161617' : '#FFFFFF';
  }
  static get text(): string {
    return readerIsDark() ? '#C9C9C7' : '#1D1D1F';
  }
  static get secondary(): string {
    return readerIsDark() ? '#7A7A7A' : '#86868B';
  }
  static get track(): string {
    return readerIsDark() ? '#3A3A3C' : '#E3DFD6';
  }
  /** 底栏半透明底色（设计稿：浅 rgba(255,255,255,.5) / 深 rgba(28,28,30,.6)） */
  static get barBg(): string {
    return readerIsDark() ? 'rgba(28,28,30,0.6)' : 'rgba(255,255,255,0.5)';
  }
  /** scrim 终色（与背景同色，用于 scrim 渐变终点） */
  static get scrimEnd(): string {
    return readerIsDark() ? '#161617' : '#FFFFFF';
  }
  /** 面板（bindSheet 内容）背景 */
  static get panelBg(): string {
    return readerIsDark() ? '#1C1C1E' : '#FFFFFF';
  }
  /** 单选胶囊未选色（设计稿：#F0EFEA） */
  static get chipIdle(): string {
    return readerIsDark() ? '#2C2C2E' : '#F0EFEA';
  }
  /** 单选胶囊选中色（设计稿：#1D1D1F / 文字白） */
  static get chipActive(): string {
    return readerIsDark() ? '#5BB5FF' : '#1D1D1F';
  }
  /** 强调色（设计稿：#0066CC） */
  static get accent(): string {
    return readerIsDark() ? '#5BB5FF' : '#0066CC';
  }
  /** 深浅模式映射 */
  static get panelHeader(): string {
    return readerIsDark() ? '#E3E5E8' : '#1D1D1F';
  }
}

/* ────────────────────────────────────────────────────────────────────────────
 * ReaderControlPanel — 设计稿 v2 重构版
 * ──────────────────────────────────────────────────────────────────────────── */
@Component
export struct ReaderControlPanel {
  /* ===== 旧有 props（保持与 ReaderHost 调用兼容） ===== */
  @Prop progress: number = 0;
  @Prop fontSizeLevel: number = 5;
  @Prop lineSpacingLevel: number = 3;
  @Prop textAlign: ReaderTextAlign = 'justify';
  @Prop turnMode: ReaderTurnMode = ReaderTurnMode.SIMULATION;
  @Prop singleHand: boolean = false;
  currentFontFamily: string = '';
  themes: Theme[] = [];
  @Link @Watch('onThemeIdChanged') currentThemeId: string;
  /** 旧兼容 prop：上一版控制栏模式 */
  barMode: MenuBarMode = MenuBarMode.DEBUG;
  margins: Margins = { left: 10, right: 10, top: 50, bottom: 36 } as Margins;
  avoidAreaBottom: number = 0;
  contentWidth: number = 344;
  canvasH: number = 800;

  /* ===== 新增可选 props（默认值保证 ReaderHost 不传也能编译运行） ===== */
  /** 进度行左侧页码文本（如 128/384）。ReaderHost 可传入 ReaderInfo.pageNumberText(...) */
  pageLabel: string = '';
  /** 设计稿「深浅模式」三选一：0=跟随系统 / 1=日间 / 2=夜间 */
  appearanceMode: number = 0;
  /** 设计稿「主题底色三档」覆盖态：-1=由 appearanceMode 决定 / 0/1/2 锁定对应 PRESET_THEMES 索引 */
  themeOverrideIndex: number = -1;
  /** 设计稿「页码显示模式」三选一：0=底部 / 1=顶部 / 2=隐藏 */
  pageNumberPlacement: number = 1;
  /** 设计稿「顶部状态栏常驻」toggle：true=始终显状态栏 / false=沉浸阅读时隐藏 */
  topStatusBarResident: boolean = true;
  /** 设计稿「底部控制栏显示」toggle：true=始终显控制栏 / false=6s 后自动隐藏 */
  bottomBarAlwaysVisible: boolean = false;
  /** 适人握持选项：0=关 / 1=自动 / 2=左手 / 3=右手 */
  holdingOption: number = 0;
  /** 亮度滑块 0.3~1.0（设计稿背景面板第 1 行；宿主接入后由 ReaderHost 端 overlay 实际生效） */
  controlBrightness: number = 1.0;

  /* ===== 液态玻璃（OhGlass）=====
   * 面板本身无背景材质，玻璃由 ReaderHost 的全屏 OhGlassSurface 按
   * GlassIds.BOTTOM_BAR 的矩形绘制；内容变化由宿主调用 OhGlass.recapture()。 */

  /* ===== 旧回调（保持兼容） ===== */
  onProgressChange: (v: number) => void = () => {};
  onQuerySeekInfo: (v: number) => SeekInfo = (_value: number): SeekInfo => {
    return { title: '', pageNum: 0, totalPages: 0 };
  };
  onPrevPage: () => void = () => {};
  onNextPage: () => void = () => {};
  onFontSizeLevelChange: (level: number) => void = () => {};
  onLineSpacingLevelChange: (level: number) => void = () => {};
  onTextAlignChange: (align: ReaderTextAlign) => void = () => {};
  onTurnModeChange: (mode: ReaderTurnMode) => void = (_selected: ReaderTurnMode): void => {};
  onSelectFont: (family: string) => void = (_familyName: string): void => {};
  onSelectTheme: (id: string) => void = (_themeId: string): void => {};
  onToggleTheme: () => void = () => {};
  onSingleHandChange: (v: boolean) => void = (_enabled: boolean): void => {};
  onOpenSettings: () => void = () => {};

  /* ===== 新增可选回调（宿主不传为 no-op） ===== */
  /** 设计稿「亮度」滑块变化（宿主可在阅读区上叠加全屏黑色半透明遮罩实现亮度调节） */
  onBrightnessChange: (v: number) => void = (_value: number): void => {};
  /** 设计稿「顶部状态栏常驻」变化 */
  onTopStatusBarResidentChange: (v: boolean) => void = (_enabled: boolean): void => {};
  /** 设计稿「底部控制栏显示」变化（true=始终显 / false=6s 自动隐藏） */
  onBottomBarAlwaysVisibleChange: (v: boolean) => void = (_enabled: boolean): void => {};
  /** 设计稿「页码显示模式」变化：0=底部 / 1=顶部 / 2=隐藏 */
  onPageNumberPlacementChange: (v: number) => void = (_mode: number): void => {};
  /** 设计稿「适人握持」变化：0=关 / 1=自动(motion) / 2=左手 / 3=右手 */
  onHoldingOptionChange: (v: number) => void = (_option: number): void => {};
  /** 控制层内任意操作（重置宿主 10s 自动隐藏计时） */
  onUserInteraction: () => void = () => {};
  /** 四入口半模态显隐变化（宿主据此暂停/恢复自动隐藏） */
  onPanelVisibilityChange: (visible: boolean) => void = (_visible: boolean): void => {};

  /* ===== 内部状态 ===== */
  @State localDark: boolean = false;
  @StorageProp('darkMode') @Watch('onDarkModeChanged') darkMode: boolean = false;
  /** 四面板 bindSheet 显隐与分类（设计稿"四个入口共用同一 @Builder，传分类枚举切换"） */
  @State @Watch('onPanelVisibleChanged') panelVisible: boolean = false;
  @State panelKind: QuickPanelKind = QuickPanelKind.BACKGROUND;
  /** 当前选中深浅模式 UI（跟随/日间/夜间） */
  @State currentAppearanceIdx: number = 0;
  /** 当前主题色卡选中的 themes 索引（设计稿"2px #0066CC 描边环"） */
  @State currentThemeSwatchIdx: number = 0;

  /* 当前深浅跟随系统：从 @StorageProp('darkMode') 推断；
   * 1=日间(对应主题 'day') / 2=夜间(对应主题 'night') */
  private static readonly APPEARANCE_LABELS: string[] = ['跟随系统', '日间', '夜间'];
  private static readonly PAGE_TURN_LABELS: string[] = ['仿真', '平移', '上下'];
  private static readonly HOLDING_LABELS: string[] = ['关', '自动', '左手', '右手'];
  private static readonly LINE_SPACING_LABELS: string[] = ['紧凑', '标准', '宽松'];
  private static readonly PAGE_PLACEMENT_LABELS: string[] = ['底部', '顶部', '隐藏'];
  private static readonly PANEL_TITLES: Record<QuickPanelKind, string> = {
    [QuickPanelKind.BACKGROUND]: '背景',
    [QuickPanelKind.PAGE_TURN]: '翻页',
    [QuickPanelKind.TYPOGRAPHY]: '排版',
    [QuickPanelKind.MORE]: '更多设置'
  };

  aboutToAppear(): void {
    this.localDark = readerIsDark();
    this.currentAppearanceIdx = this.appearanceMode;
    // 初始主题色卡选中的索引：themes 中第一个非 night 的主题（设计稿"夜间不放色卡"）
    if (this.themes.length > 0) {
      const found: number = this.themes.findIndex((t: Theme): boolean => t.id === this.currentThemeId);
      this.currentThemeSwatchIdx = found >= 0 ? found : 0;
    }
  }

  /** @Watch：外部主题变化时同步本地深色态（驱动图标配色；玻璃重截由宿主 refreshPage 触发） */
  private onThemeIdChanged(): void {
    this.localDark = readerIsDark();
  }

  /** @Watch：系统深浅色变化：同步本地深色态驱动面板重绘 */
  private onDarkModeChanged(): void {
    this.localDark = this.darkMode;
  }

  // ─── 业务派发辅助 ──────────────────────────────────────────────────────────
  /** 字号 slider 实际档位（夹到 1..FONT_SIZE_LEVELS.length 范围） */
  private clampedFontLevel(): number {
    return Math.max(1, Math.min(FONT_SIZE_LEVELS.length, this.fontSizeLevel));
  }

  /** 行距层级当前在三档（紧凑/标准/宽松）中的索引 */
  private lineSpacingSegIdx(): number {
    // LINE_SPACING_PRESETS = [1,3,5]，找最接近的 preset
    let bestIdx: number = 1;
    let bestDiff: number = Math.abs(this.lineSpacingLevel - LINE_SPACING_PRESETS[0]);
    for (let i: number = 1; i < LINE_SPACING_PRESETS.length; i++) {
      const diff: number = Math.abs(this.lineSpacingLevel - LINE_SPACING_PRESETS[i]);
      if (diff < bestDiff) {
        bestDiff = diff;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  /** 深浅模式 UI 选中项映射到日间/夜间主题 id（仅在调用 applyAppearance 时使用） */
  private applyAppearance(idx: number): void {
    this.currentAppearanceIdx = idx;
    if (idx === 1) {
      this.onSelectTheme('day');
    } else if (idx === 2) {
      this.onSelectTheme('night');
    } else {
      // 跟随系统：使用当前系统 dark 决定主题
      this.onSelectTheme(this.localDark ? 'night' : 'day');
    }
  }

  /** 主题底色三档：themes 中过滤掉 night（设计稿"夜间不放色卡，由深浅模式统一控制"） */
  private dayTimeThemes(): Theme[] {
    return this.themes.filter((t: Theme): boolean => t.id !== 'night');
  }

  private panelTitle(): string {
    return ReaderControlPanel.PANEL_TITLES[this.panelKind];
  }

  /** 打开面板并记录"上次打开的分类"（设计稿"面板记住上次打开的分类，下次直接落在同一分类"） */
  private openPanel(kind: QuickPanelKind): void {
    this.panelKind = kind;
    this.panelVisible = true;
    this.onUserInteraction();
  }

  /** bindSheet 显隐变化：通知宿主暂停/恢复自动隐藏；关闭时重置计时 */
  private onPanelVisibleChanged(): void {
    this.onPanelVisibilityChange(this.panelVisible);
    if (!this.panelVisible) {
      this.onUserInteraction();
    }
  }

  /** 适人握持自动模式：尝试订阅 motion.on('holdingHandChanged')（API 20+，权限 DETECT_GESTURE）。
   *  设计稿明确要求 801 回退手动；此处不做 try/catch，把副作用交给调用层 */
  private tryAutoDetectHolding(): boolean {
    // 真接入由宿主在 onHoldingOptionChange 回调里实现；本组件内仅做 UI 与状态管理。
    // 设备能力检测由宿主完成（@kit.MultimodalAwarenessKit.isSupported / 801 错误码）。
    return false;
  }

  /** 应用适人握持：关/左手/右手 → onSingleHandChange；自动 → 触发 onHoldingOptionChange(1) 让宿主订阅 motion */
  private applyHoldingOption(idx: number): void {
    this.holdingOption = idx;
    this.onHoldingOptionChange(idx);
    if (idx === 0) {
      this.onSingleHandChange(false);
    } else if (idx === 2 || idx === 3) {
      // 左手/右手 → 开启单手模式（当前引擎 singleHand 为 bool，左右差异由手势控制器扩展）
      this.onSingleHandChange(true);
    }
    // idx === 1（自动）由宿主在 onHoldingOptionChange 中订阅 motion holdingHandChanged 并处理 801
  }

  /** 主题底色点击：onSelectTheme(themes[i].id) */
  private applyThemeSwatch(idx: number): void {
    const dayThemes: Theme[] = this.dayTimeThemes();
    if (idx >= 0 && idx < dayThemes.length) {
      this.currentThemeSwatchIdx = idx;
      this.onSelectTheme(dayThemes[idx].id);
    }
  }

  // ─── 主 build ───────────────────────────────────────────────────────────────
  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 底部控制栏（距屏幕底部 = 安全区 + 29vp）
      Column() {
        this.controlBar()
      }
      .width('100%')
      .padding({ bottom: this.avoidAreaBottom + 29 })
    }
    .width('100%')
    .height(200)
    .position({ left: 0, bottom: 0 })
    .zIndex(100)
    // 设计稿：4 入口共用一个 @Builder + bindSheet 半模态（SheetSize.FIT_CONTENT）
    // 沉浸光感：容器级 SheetOptions.systemMaterial（API26 真渲染）；
    // API24 由 MaterialConfig 自动回退为 blurStyle + 半透明底（systemMaterial=undefined）。
    .bindSheet($$this.panelVisible, this.sheetBuilder(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      showClose: false,
      preferType: SheetType.BOTTOM,
      systemMaterial: MaterialConfig.sheetMaterial()
    })
  }

  /* ─── 底部控制栏：液态玻璃面板（OhGlass）+ 两行内容 ─── */
  @Builder
  controlBar() {
    Column() {
      Column({ space: GLASS_GAP }) {
        this.progressRow()
        this.buttonRow()
      }
      .width('100%')
      .height(GLASS_PANEL_H)
      // 玻璃面板：背景必须透明 + 显式关掉系统材质；玻璃由全屏 OhGlassSurface 绘制
      .id(GlassIds.BOTTOM_BAR)
      .backgroundColor('#00000000')
      .systemMaterial(uiMaterial.Material.empty)
      .onTouch((ev: TouchEvent): void => {
        OhGlass.touch(ev, GlassIds.BOTTOM_BAR);
      })
      .onAreaChange((): void => {
        OhGlass.refresh();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  /* ─── 进度行（玻璃之上，透明内容） ─── */
  @Builder
  progressRow() {
    Row() {
      Row() {
        // 左侧图标 = 右侧箭头镜像（朝向相反）
        Image(IconAssets.nextPage())
          .width(20).height(20)
          .objectFit(ImageFit.Contain)
          .fillColor(ControlTokens.secondary)
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
          .fillColor(ControlTokens.secondary)
      }
      .width(SIDE_ZONE).height('100%')
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onNextPage();
      })
    }
    .width('100%')
    .height(GLASS_ROW_H)
    .padding({ left: ROW_PAD, right: ROW_PAD })
    .alignItems(VerticalAlign.Center)
  }

  /* ─── 按钮行（玻璃之上，透明；四个入口平分整行） ─── */
  @Builder
  buttonRow() {
    Row() {
      this.panelSegment(QuickPanelKind.BACKGROUND, IconAssets.theme())
      this.panelSegment(QuickPanelKind.TYPOGRAPHY, IconAssets.font())
      this.panelSegment(QuickPanelKind.PAGE_TURN, IconAssets.nextPage())
      this.panelSegment(QuickPanelKind.MORE, IconAssets.settings())
    }
    .width('100%')
    .height(GLASS_ROW_H)
  }

  /* ─── 长胶囊内的一段（无独立背景，图标 24pt 居中） ─── */
  @Builder
  panelSegment(kind: QuickPanelKind, icon: Resource) {
    Column() {
      Image(icon)
        .width(24).height(24)
        .objectFit(ImageFit.Contain)
        .fillColor(this.iconColor())
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.openPanel(kind);
    })
  }

  /** 图标色：深色底（夜间/系统深色/深色阅读主题）用纯白，浅色底用主文字色 */
  private iconColor(): string {
    return this.isDarkTheme() ? '#FFFFFF' : ControlTokens.text;
  }

  /** 当前是否深色底（系统深色 / 夜间 / 当前主题底色偏暗） */
  private isDarkTheme(): boolean {
    if (this.localDark || this.currentThemeId === 'night') {
      return true;
    }
    const t: Theme | undefined = this.themes.find((x: Theme): boolean => x.id === this.currentThemeId);
    if (t === undefined) {
      return false;
    }
    return ReaderControlPanel.hexLuminance(t.backgroundColor) < 0.5;
  }

  /** 十六进制颜色亮度（0~1，解析失败按亮色处理） */
  private static hexLuminance(hex: string): number {
    let h: string = hex.trim();
    if (h.startsWith('#')) {
      h = h.substring(1);
    }
    if (h.length === 3) {
      h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    }
    if (h.length < 6) {
      return 1;
    }
    const r: number = parseInt(h.substring(0, 2), 16);
    const g: number = parseInt(h.substring(2, 4), 16);
    const b: number = parseInt(h.substring(4, 6), 16);
    if (Number.isNaN(r) || Number.isNaN(g) || Number.isNaN(b)) {
      return 1;
    }
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  }

  /* ─── bindSheet 内容（280pt 高：抓柄 + 头部 + 3 行模板） ─── */
  @Builder
  sheetBuilder() {
    Column() {
      // 抓柄 32×4（设计稿"抓柄 32×4"）
      Row() {
        Column()
          .width(32).height(4)
          .borderRadius(2)
          .backgroundColor(ControlTokens.track)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 8 })

      // 头部 32pt：分类名 15pt Medium + 关闭（设计稿"头部 32pt（分类名 15pt Medium + 关闭）"）
      Row() {
        Text(this.panelTitle())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ControlTokens.panelHeader)
        Blank()
        Column() {
          Image(IconAssets.cancel())
            .width(16).height(16)
            .objectFit(ImageFit.Contain)
            .fillColor(ControlTokens.secondary)
        }
        .width(28).height(28)
        .borderRadius(14)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => {
          this.panelVisible = false;
        })
      }
      .width('100%')
      .height(32)
      .padding({ left: 20, right: 20 })

      // 内容：3 行模板（行高 40、行距 12；标签 13pt 左 / 控件右 240pt）
      Column() {
        if (this.panelKind === QuickPanelKind.BACKGROUND) {
          this.backgroundPanel();
        } else if (this.panelKind === QuickPanelKind.PAGE_TURN) {
          this.pageTurnPanel();
        } else if (this.panelKind === QuickPanelKind.TYPOGRAPHY) {
          this.typographyPanel();
        } else if (this.panelKind === QuickPanelKind.MORE) {
          this.morePanel();
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 20, right: 20 })
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(280)
    .backgroundColor(MaterialConfig.sheetBg())
    .backgroundBlurStyle(MaterialConfig.sheetBlur())
    .borderRadius({ topLeft: 24, topRight: 24 })
  }

  /* ─── 行模板：标签 13pt 左 / 控件 240pt 右；行高 40 ─────
   * 由下方自定义组件 ReaderPanelRow + @BuilderParam 实现（尾随闭包传入控件内容） */

  /* ─── 单选胶囊（自绘：ChipGroup 无 border/圆角定制，圆角 20 用自绘保证） ─── */
  @Builder
  capsuleGroup(options: string[], selectedIdx: number, onSelect: (idx: number) => void) {
    Row({ space: 6 }) {
      ForEach(options, (label: string, idx: number): void => {
        Row() {
          Text(label)
            .fontSize(13)
            .fontColor(idx === selectedIdx ? '#FFFFFF' : ControlTokens.text)
            .fontWeight(idx === selectedIdx ? FontWeight.Medium : FontWeight.Normal)
        }
        .height(40)
        .padding({ left: 14, right: 14 })
        .backgroundColor(idx === selectedIdx ? ControlTokens.chipActive : ControlTokens.chipIdle)
        .borderRadius(20)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          onSelect(idx);
        })
      }, (label: string, idx: number): string => `${idx}_${label}`);
    }
    .width(240)
    .justifyContent(FlexAlign.End)
  }

  /* ─── 面板1：背景（亮度 + 深浅模式 + 主题底色三档） ─── */
  @Builder
  backgroundPanel() {
    Column({ space: 12 }) {
      // 行1：亮度 slider（设计稿：Slider 与进度条同语言；4pt轨道/18px拇指）
      ReaderPanelRow({ label: '亮度' }) {
        Slider({
          value: this.controlBrightness,
          min: 0.3,
          max: 1.0,
          step: 0.01,
          style: SliderStyle.OutSet
        })
          .width(240)
          .blockSize({ width: 18, height: 18 })
          .trackThickness(4)
          .selectedColor(ControlTokens.text)
          .trackColor(ControlTokens.track)
          .blockColor('#FFFFFF')
          .onChange((value: number, mode: SliderChangeMode): void => {
            this.controlBrightness = value;
            this.onBrightnessChange(value);
          });
      }

      // 行2：深浅模式 跟随系统/日间/夜间
      ReaderPanelRow({ label: '深浅模式' }) {
        this.capsuleGroup(
          ReaderControlPanel.APPEARANCE_LABELS,
          this.currentAppearanceIdx,
          (idx: number): void => {
            this.applyAppearance(idx);
          }
        );
      }

      // 行3：主题底色三档（宣纸白/纸黄/护眼绿）+ 2px #0066CC 描边环选中
      // 设计稿"夜间不放色卡，由深浅模式统一控制" → 过滤 themes 中 night
      ReaderPanelRow({ label: '主题底色' }) {
        Row({ space: 8 }) {
          ForEach(this.dayTimeThemes(), (t: Theme, idx: number): void => {
            Column() {
              Column()
                .width(36).height(36)
                .borderRadius(18)
                .backgroundColor(t.backgroundColor)
                .border({
                  width: idx === this.currentThemeSwatchIdx ? 2 : 0.5,
                  color: idx === this.currentThemeSwatchIdx ? ControlTokens.accent : ControlTokens.track
                })
            }
            .width(44).height(44)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .onClick(() => {
              this.applyThemeSwatch(idx);
            })
          }, (t: Theme, idx: number): string => `${idx}_${t.id}`);
        }
        .width(240)
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
  }

  /* ─── 面板2：翻页（翻页方式 + 适人握持翻页） ─── */
  @Builder
  pageTurnPanel() {
    Column({ space: 12 }) {
      // 行1：翻页方式 仿真/平移/上下
      // 现有 turnMode 四态 (SIMULATION/HORIZONTAL/VERTICAL/NONE)；设计稿三选一不含"无动效"，默认三档
      ReaderPanelRow({ label: '翻页方式' }) {
        this.capsuleGroup(
          ReaderControlPanel.PAGE_TURN_LABELS,
          this.pageTurnSegIdx(),
          (idx: number): void => {
            this.onTurnModeChange(this.turnModeOfSegIdx(idx));
          }
        );
      }

      // 行2：适人握持翻页 关/自动/左手/右手
      // 设计稿：自动 = motion.on('holdingHandChanged')(20+,权限 DETECT_GESTURE)；801 回退手动
      ReaderPanelRow({ label: '适人握持' }) {
        this.capsuleGroup(
          ReaderControlPanel.HOLDING_LABELS,
          this.holdingOption,
          (idx: number): void => {
            this.applyHoldingOption(idx);
          }
        );
      }
    }
    .width('100%')
  }

  /** turnMode ∈ {SIMULATION,HORIZONTAL,VERTICAL,NONE} → 设计稿 3 段映射（NONE 归为 SIMULATION） */
  private pageTurnSegIdx(): number {
    switch (this.turnMode) {
      case ReaderTurnMode.HORIZONTAL: return 1;
      case ReaderTurnMode.VERTICAL: return 2;
      default: return 0; // SIMULATION + NONE
    }
  }

  private turnModeOfSegIdx(idx: number): ReaderTurnMode {
    switch (idx) {
      case 1: return ReaderTurnMode.HORIZONTAL;
      case 2: return ReaderTurnMode.VERTICAL;
      default: return ReaderTurnMode.SIMULATION;
    }
  }

  /* ─── 面板3：排版（字号 + 行距 + 字体+对齐） ─── */
  @Builder
  typographyPanel() {
    Column({ space: 12 }) {
      // 行1：字号 slider 10档 n/10（设计稿"10 个档位，右侧显示 n/10"）
      ReaderPanelRow({ label: '字号' }) {
        Row() {
          Slider({
            value: this.clampedFontLevel(),
            min: 1,
            max: FONT_SIZE_LEVELS.length,
            step: 1,
            style: SliderStyle.OutSet
          })
            .layoutWeight(1)
            .blockSize({ width: 18, height: 18 })
            .trackThickness(4)
            .selectedColor(ControlTokens.text)
            .trackColor(ControlTokens.track)
            .blockColor('#FFFFFF')
            .onChange((value: number, mode: SliderChangeMode): void => {
              this.onFontSizeLevelChange(Math.round(value));
            });

          Text(`${this.clampedFontLevel()}/${FONT_SIZE_LEVELS.length}`)
            .fontSize(12)
            .fontColor(ControlTokens.accent)
            .fontWeight(FontWeight.Medium)
            .width(40)
            .textAlign(TextAlign.End)
            .margin({ left: 8 })
        }
        .width(240)
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Center)
      }

      // 行2：行距 紧凑/标准/宽松
      ReaderPanelRow({ label: '行间距' }) {
        this.capsuleGroup(
          ReaderControlPanel.LINE_SPACING_LABELS,
          this.lineSpacingSegIdx(),
          (idx: number): void => {
            this.onLineSpacingLevelChange(LINE_SPACING_PRESETS[idx]);
          }
        );
      }

      // 行3：字体 + 对齐方式（设计稿"字体四选一横向 List + 对齐三图标按钮"）
      ReaderPanelRow({ label: '字体与对齐' }) {
        Row() {
          // 字体：横向滑动 List 四选一（设计稿"字体四选一横向滑动"）
          // 注意 ArkUI Column 内嵌 List(lanes=1, listDirection=Axis.Horizontal)
          List({ space: 6 }) {
            ForEach(FONT_PRESETS, (preset: FontPreset, idx: number): void => {
              ListItem() {
                Text(preset.name)
                  .fontSize(12)
                  .fontColor(this.currentFontFamily === preset.family ? '#FFFFFF' : ControlTokens.text)
                  .fontWeight(this.currentFontFamily === preset.family ? FontWeight.Medium : FontWeight.Normal)
                  .height(28)
                  .padding({ left: 10, right: 10 })
                  .borderRadius(14)
                  .backgroundColor(this.currentFontFamily === preset.family ? ControlTokens.chipActive : ControlTokens.chipIdle)
                  .onClick(() => {
                    this.onSelectFont(preset.family);
                  })
              }
            }, (preset: FontPreset, idx: number): string => `${idx}_${preset.family}`);
          }
          .listDirection(Axis.Horizontal)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
          .height(32)
          .layoutWeight(1)
          .constraintSize({ maxWidth: 160 })

          // 对齐：三个图标按钮（左对齐 / 两端 / 居中）
          Row({ space: 4 }) {
            this.alignIconBtn('L', 'left', this.textAlign === 'left')
            this.alignIconBtn('≡', 'justify', this.textAlign === 'justify')
            this.alignIconBtn('⊟', 'center', this.textAlign === 'center')
          }
          .height(28)
          .alignItems(VerticalAlign.Center)
        }
        .width(240)
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
  }

  /** 对齐图标按钮（设计稿"三个图标按钮 左对齐 / 两端 / 居中"） */
  @Builder
  alignIconBtn(symbol: string, mode: string, active: boolean) {
    Text(symbol)
      .fontSize(14)
      .fontColor(active ? '#FFFFFF' : ControlTokens.text)
      .fontWeight(active ? FontWeight.Bold : FontWeight.Normal)
      .height(28)
      .width(32)
      .borderRadius(14)
      .backgroundColor(active ? ControlTokens.chipActive : ControlTokens.chipIdle)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        if (mode === 'left' || mode === 'justify' || mode === 'center') {
          this.onTextAlignChange(mode);
        }
      })
  }

  /* ─── 面板4：更多设置（顶部状态栏常驻 / 底部控制栏显示 / 页码显示模式） ─── */
  @Builder
  morePanel() {
    Column({ space: 12 }) {
      // 行1：顶部状态栏常驻 Toggle（设计稿"顶部状态栏常驻 Toggle（window.setWindowSystemBarProperties/setWindowLayoutFullScreen）"）
      ReaderPanelRow({ label: '顶部状态栏' }) {
        Toggle({ type: ToggleType.Switch, isOn: this.topStatusBarResident })
          .selectedColor(ControlTokens.chipActive)
          .switchPointColor('#FFFFFF')
          .width(44).height(24)
          .borderRadius(12)
          .onChange((isOn: boolean): void => {
            this.topStatusBarResident = isOn;
            this.onTopStatusBarResidentChange(isOn);
          });
      }

      // 行2：底部控制栏显示 Toggle
      ReaderPanelRow({ label: '底部控制栏' }) {
        Toggle({ type: ToggleType.Switch, isOn: this.bottomBarAlwaysVisible })
          .selectedColor(ControlTokens.chipActive)
          .switchPointColor('#FFFFFF')
          .width(44).height(24)
          .borderRadius(12)
          .onChange((isOn: boolean): void => {
            this.bottomBarAlwaysVisible = isOn;
            this.onBottomBarAlwaysVisibleChange(isOn);
          });
      }

      // 行3：页码显示模式 底部/顶部/隐藏
      ReaderPanelRow({ label: '页码位置' }) {
        this.capsuleGroup(
          ReaderControlPanel.PAGE_PLACEMENT_LABELS,
          this.pageNumberPlacement,
          (idx: number): void => {
            this.pageNumberPlacement = idx;
            this.onPageNumberPlacementChange(idx);
          }
        );
      }
    }
    .width('100%')
  }
}

/* ────────────────────────────────────────────────────────────────────────────
 * ReaderPanelRow — 面板行模板组件：标签 13pt 左 / 控件 240pt 右；行高 40
 * 通过 @BuilderParam（尾随闭包）接收控件内容，替代旧 panelRow 的闭包参数写法
 * ──────────────────────────────────────────────────────────────────────────── */
@Component
struct ReaderPanelRow {
  /** 行标签文案 */
  label: string = '';

  @Builder
  private emptySlot() {
  }

  /** 控件内容插槽：parent 通过尾随闭包传入 */
  @BuilderParam
  slotBuilder: () => void = this.emptySlot;

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .fontColor(ControlTokens.secondary)
        .layoutWeight(1)
      Column() {
        this.slotBuilder();
      }
      .width(240)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .height(40)
    .alignItems(VerticalAlign.Center)
  }
}

/* 旧内部辅助隐藏 SymbolGlyph 箭头修饰器（v2 重构后未使用，但保留以兼容可能的未来扩展） */
function _unusedSymbolArrow(): SymbolGlyphModifier {
  const m: SymbolGlyphModifier = new SymbolGlyphModifier();
  m.fontColor(['#00000000']);
  return m;
}