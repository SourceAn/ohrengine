/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * ReaderHost — 可复用阅读器主屏（EPUB/TXT / 单手菜单 / 翻页动画）。
 *
 * 由宿主页面嵌入使用：
 *   import { ReaderHost, ReaderFeatureFlags } from 'ohrengine-reader';
 *
 *   ReaderHost({
 *     bookPath: '/data/storage/.../book.epub',
 *     barMode: MenuBarMode.TEST,
 *     featureFlags: ReaderFeatureFlags.minimal()
 *   })
 *
 * 能力开关（featureFlags）裁剪：
 *   - annotations / bookmarks / exportAnnotations / listen / translation
 * 默认全部开启；最小集（minimal()）仅保留：阅读 + 菜单 + 翻页动画。
 */

import { OhEngine } from 'ohrengine-ui-render';
import { Margins, TurnDirection, ReaderFeatureFlags, TocItem, Annotation, AnnotationType, Locator, FontRegistrar, FontTheme, DiskCacheQuotaManager, ImportCheckpoint, ImportStage, ImportService, ImportStatus } from 'ohrengine-common';
import type { LineBox, PageSlot, ImportRequest, ImportResult, ImportedBook } from 'ohrengine-common';
import { fileIo } from '@kit.CoreFileKit';
import { window, display, UIContext, curves } from '@kit.ArkUI';
import { ThemePreferenceStorage, Theme, PRESET_THEMES, SelectionRange, ContextMenuManager, AnnotationExporter, BookmarkStorage, Bookmark } from 'ohrengine-feature';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PageRenderer, ReaderViewport } from './reader/PageRenderer.ets';
import { ReaderGestureController } from './reader/ReaderGestureController.ets';
import { FlipPageController } from './reader/FlipPageController.ets';
import { SlideTurnController } from './reader/SlideTurnController.ets';
import { SelectionContextMenu } from './panels/SelectionContextMenu.ets';
import { ReaderControlPanel, MenuBarMode, BOTTOM_BAR_RADIUS_VP } from './panels/ReaderControlPanel.ets';
import { ReaderTopBar } from './panels/ReaderTopBar.ets';
import { ReaderSettingsPanel } from './panels/ReaderSettingsPanel.ets';
import { AutoTurnBar } from './panels/AutoTurnBar.ets';
import { ReaderStatusBar } from './panels/ReaderStatusBar.ets';
import { ReaderInfo } from './reader/ReaderInfo.ets';
import { BatteryMonitor } from './service/BatteryMonitor.ets';
import { ReaderThemeUtils } from './utils/ReaderThemeUtils.ets';
import { ReaderTextUtils } from './utils/ReaderTextUtils.ets';
import { TocPanel } from './panels/TocPanel.ets';
import { MaterialConfig } from './common/MaterialConfig.ets';
import { OhGlass, OhGlassKind, OhGlassSurface } from './glass/OhGlass.ets';
import { GlassIds } from './glass/GlassIds.ets';
import { ControlSpec } from './common/ControlSpec.ets';
import { readerIsDark } from './common/ReaderTheme.ets';
import { IconAssets } from './common/IconAssets.ets';
import type { SeekInfo } from './panels/ReaderScrubBar.ets';
import { ApiConfigPanel } from './panels/ApiConfigPanel.ets';
import { AnnotationPanel } from './panels/AnnotationPanel.ets';
import { ReaderSettings, ReaderTurnMode, ReaderPageNumberMode, ReaderTextAlign, FONT_SIZE_LEVELS, LINE_SPACING_LEVELS } from './utils/ReaderSettings.ets';
import { formatClock, readSoc, readCharging } from './utils/ReaderStatus.ets';
import { WordLookupDialog } from './WordLookupDialog.ets';

/** 引擎打开的书籍来源描述（由 ImportService 统一入口产出） */
interface BookSource {
  sourcePath: string;
  bookBasePath: string;
  cacheDir: string;
  libraryDir: string;
}

const READER_TAG: string = 'OhEngine-Reader';

@Component
export struct ReaderHost {
  /** 宿主传入的书籍路径（必填：EPUB 或 TXT；空串时显示错误而非加载内置兜底资源） */
  bookPath: string = '';
  /** 底部菜单栏模式（调用引擎时选择：test=单手菜单，debug=调试） */
  barMode: MenuBarMode = MenuBarMode.DEBUG;
  /** 阅读功能能力开关（默认全开，宿主可传 ReaderFeatureFlags.minimal() 裁剪） */
  featureFlags: ReaderFeatureFlags = ReaderFeatureFlags.allOn();
  /** 可选：打开词汇表页回调（未提供时词汇表入口显示占位提示） */
  onOpenVocabulary: ((engine: OhEngine) => void) | undefined = undefined;
  /** 音量键翻页：true 时音量上=上一页、音量下=下一页（经 ReaderGestureController 处理） */
  volumeKeyFlip: boolean = false;

  /** 引擎（阅读器核心；字段初始化顺序在 currentFontThemeId 之前） */
  private engine: OhEngine = new OhEngine();
  @State currentFontThemeId: string = this.engine.getFontThemeManager().currentTheme.id;
  @State engineState: string = '初始化中';
  @State errorMsg: string = '';
  @State @Watch('onControlsVisibleChanged') showControls: boolean = false;
  /** 底部四入口半模态是否打开（打开时暂停控制层自动隐藏） */
  @State quickPanelOpen: boolean = false;
  /** 顶部状态栏常驻（true=控制层隐藏时仍显示状态栏） */
  @State topStatusBarResident: boolean = false;
  /** 顶部状态栏当前是否显示 */
  private statusBarVisible: boolean = false;
  @State showSettings: boolean = false;
  @State autoTurning: boolean = false;
  @State showAutoTurnBar: boolean = false;
  @State autoSpeed: number = 0.8;
  @State chapterTotalPages: number = 0;
  @State chapterCurrentPage: number = 0;
  @State currentPageNum: number = 0;
  @State totalPages: number = 0;
  @State pageLines: LineBox[] = [];
  @State screenDensity: number = 3.5;
  @State margins: Margins = { left: 10, right: 10, top: 50, bottom: 36 } as Margins;
  @State selection: SelectionRange | null = null;
  @State annotations: Annotation[] = [];
  @State bookmarks: Bookmark[] = [];
  /** 底部液态玻璃：顶栏/底栏显隐后重算玻璃矩形并重截背景 */
  @State showAnnotationPanel: boolean = false;
  /** 当前主题 id（主题切换实时同步，驱动深色/明亮按钮即时刷新） */
  @State currentThemeId: string = 'day';
  /** 下拉添加书签：当前内容下移位移（vp） */
  @State @Watch('onPullDistanceChanged') pullDistance: number = 0;
  /** 下拉添加书签：书签填充进度 0~1 */
  @State pullProgress: number = 0;
  private static readonly PULL_TRIGGER: number = 80;
  private bookmarkStorage: BookmarkStorage = new BookmarkStorage();
  @State selectionMenuX: number = 0;
  @State selectionMenuY: number = 0;
  @State showTranslate: boolean = false;
  @State showDictionary: boolean = false;
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D();
  @State contentWidth: number = 344;
  @State contentHeight: number = 524;
  @State canvasW: number = 360;
  @State canvasH: number = 800;
  @State avoidAreaBottom: number = 0;
  @State avoidAreaTopVp: number = 0;
  private lookupDialogController: CustomDialogController | null = null;
  /** 目录 / 笔记自定义弹窗控制器（CustomDialog，不使用沉浸光感） */
  private tocDialogController: CustomDialogController | null = null;
  @State showApiConfig: boolean = false;
  @State apiConfigName: string = '';
  @State apiConfigEndpoint: string = '';
  @State apiConfigMessage: string = '';
  // ── 阅读器新设置 ──
  @State turnMode: ReaderTurnMode = ReaderTurnMode.SIMULATION;
  @State singleHand: boolean = false;
  @State eyeTracking: boolean = false;
  @State pageNumberMode: ReaderPageNumberMode = ReaderPageNumberMode.TOTAL;
  @State textAlignMode: ReaderTextAlign = 'justify';
  @State fontSizeLevel: number = 5;
  @State lineSpacingLevel: number = 3;
  // ── 状态条 ──
  @State timeText: string = '--:--';
  @State batteryCharging: boolean = false;
  @State batterySoc: number = -1;
  // 电池状态事件订阅（实时电量图标）
  private batteryMonitor: BatteryMonitor = new BatteryMonitor();
  // 窗口监听生命周期（ENG-001）：保存 window 引用与回调，aboutToDisappear 成对注销
  private mainWindow: window.Window | null = null;
  private onWindowSizeChangeCb: (size: window.Size) => void = (size: window.Size): void => {
    if (this.pageDestroyed) {
      return;
    }
    const ml2: number = this.margins.left;
    const mr2: number = this.margins.right;
    const mt2: number = this.margins.top;
    const mb2: number = this.margins.bottom;
    const avoidH2: number = this.avoidAreaTopVp + this.avoidAreaBottom;
    if (this.flipController.isActive()) {
      this.flipController.cancel();
    }
    const newOrientation: 'landscape' | 'portrait' = size.width > size.height ? 'landscape' : 'portrait';
    this.engine.mediaContext.orientation = newOrientation;
    this.engine.mediaContext.viewWidth = Math.round(size.width / this.screenDensity) - ml2 - mr2;
    this.engine.mediaContext.viewHeight = Math.round(size.height / this.screenDensity) - mt2 - mb2 - avoidH2;
    this.engine.recompileCss();
    this.refreshPage();
  };
  // 页面销毁标记
  private pageDestroyed: boolean = false;
  /** Phase 11.3: pageReady 监听已注册标记（open 前注册，只注册一次） */
  private pageReadyRegistered: boolean = false;
  /** P0-B: 引擎 Session 已销毁标记（disposeEngine 幂等） */
  private engineDestroyed: boolean = false;
  /** P0-B: initEngine 单飞行 */
  private initInFlight: Promise<void> | null = null;
  // 定时器
  private statusTimer: number = -1;
  private autoTurnTimer: number = -1;
  /** 控制层（顶栏+底栏）无操作自动隐藏定时器 */
  private controlsTimer: number = -1;
  private static readonly CONTROLS_AUTO_HIDE_MS: number = 10000;
  private pageRenderer: PageRenderer = new PageRenderer({
    engine: this.engine,
    canvasCtx: this.canvasCtx,
    getViewport: () => this.getReaderViewport(),
    getAnnotations: () => this.annotations,
    getSelection: () => this.selection,
    getPullDistance: () => this.pullDistance,
    getPullProgress: () => this.pullProgress,
    onContentChanged: () => {
      if (this.pageDestroyed) {
        return;
      }
      if (this.flipController.isActive()) {
        return;
      }
      this.pageRenderer.renderPage();
    },
    isFlipActive: () => this.flipController.isActive()
  });
  // 仿真翻页控制器
  private flipController: FlipPageController = new FlipPageController({
    engine: this.engine,
    pageRenderer: this.pageRenderer,
    canvasCtx: this.canvasCtx,
    getViewport: () => this.getReaderViewport(),
    onPageTurned: (direction: TurnDirection) => {
      if (this.pageDestroyed) {
        return;
      }
      const ok: boolean = this.engine.turnPage(direction);
      if (ok) {
        this.refreshPage();
        this.logPageTurnSnapshot('flipTurned');
      } else {
        this.pageRenderer.renderPage();
      }
    },
    onFlipStateChange: (active: boolean) => {
      if (this.pageDestroyed) {
        return;
      }
      if (active) {
        this.hideControls();
        this.selection = null;
      }
    }
  });
  // 横滑/上下滑动补间翻页控制器（HORIZONTAL/VERTICAL 模式）
  private slideController: SlideTurnController = new SlideTurnController({
    engine: this.engine,
    pageRenderer: this.pageRenderer,
    canvasCtx: this.canvasCtx,
    getViewport: () => this.getReaderViewport(),
    onPageTurned: (direction: TurnDirection) => {
      if (this.pageDestroyed) {
        return;
      }
      const ok: boolean = this.engine.turnPage(direction);
      if (ok) {
        this.refreshPage();
        this.logPageTurnSnapshot('slideTurned');
      } else {
        this.pageRenderer.renderPage();
      }
    },
    onFlipStateChange: (active: boolean) => {
      if (this.pageDestroyed) {
        return;
      }
      if (active) {
        this.hideControls();
        this.selection = null;
      }
    }
  });
  private gestureController: ReaderGestureController = new ReaderGestureController({
    getSelection: () => this.selection,
    setSelection: (s: SelectionRange | null) => {
      if (s !== null) {
        // 拖动扩选后重算选中文本（handleTouchMove 只更新起止偏移与行索引）
        s.text = this.computeSelectionText(s);
        this.selection = s;
        this.updateSelectionMenu();
      } else {
        this.selection = null;
      }
    },
    getPageLines: () => this.pageLines,
    getContentWidth: () => this.contentWidth,
    getContentHeight: () => this.contentHeight,
    getMargins: () => this.margins,
    onRenderPage: () => this.pageRenderer.renderPage(),
    onHideControls: () => this.hideControls(),
    onToggleControls: () => {
      this.showControls = !this.showControls;
      this.showSettings = false;
      if (this.showControls) {
        this.scheduleControlsAutoHide();
        this.setStatusBarVisible(true);
      } else {
        this.cancelControlsAutoHide();
        if (!this.topStatusBarResident) {
          this.setStatusBarVisible(false);
        }
      }
    },
    getTurnMode: () => this.turnMode,
    getSingleHand: () => this.singleHand,
    isAutoTurning: () => this.autoTurning,
    onAutoTurnTap: () => {
      if (this.pageDestroyed) {
        return;
      }
      this.onAutoTurnTap();
    },
    onQuickTurn: (direction: TurnDirection) => {
      if (this.pageDestroyed) {
        return;
      }
      const ok: boolean = this.engine.turnPage(direction);
      if (ok) {
        this.refreshPage();
        this.logPageTurnSnapshot('quickTurned');
      } else {
        this.pageRenderer.renderPage();
      }
    },
    getSlideTurn: () => this.slideController,
    flip: this.flipController,
    onBookmarkPullMove: (dy: number) => {
      if (this.pageDestroyed) {
        return;
      }
      this.pullProgress = Math.min(1, Math.max(0, dy) / ReaderHost.PULL_TRIGGER);
      this.pullDistance = Math.max(0, dy);
    },
    onBookmarkPullEnd: (add: boolean) => {
      if (this.pageDestroyed) {
        return;
      }
      hilog.info(0x0000, READER_TAG, 'bookmarkPullEnd add=%{public}d pullDis=%{public}d',
        add ? 1 : 0, Math.round(this.pullDistance));
      if (add) {
        this.toggleBookmarkAtCurrentPage();
      }
      // 弹簧回弹：物理阻尼逐帧驱动画布重绘（@Watch onPullDistanceChanged）
      this.getUIContext().animateTo({
        duration: 360,
        curve: curves.springMotion(0.45, 0.88, 0)
      }, () => {
        this.pullProgress = 0;
        this.pullDistance = 0;
      });
    },
    // Phase 16.3: 选择交互前按需恢复当前页逐字几何
    ensurePageLinesGeometry: () => {
      if (!this.pageDestroyed) {
        this.engine.ensureCurrentPageGeometry();
      }
    },
    getVolumeFlip: (): boolean => this.volumeKeyFlip,
    onVolumeKeyTurn: (direction: TurnDirection): void => {
      if (this.pageDestroyed) {
        return;
      }
      // 音量键翻页 = 点击翻页逻辑（带动画）
      this.gestureController.turnPageWithAnimation(direction);
    }
  });

  aboutToAppear(): void {
    this.pageDestroyed = false;
    // 液态玻璃登记：顶栏两个圆钮（胶囊）+ 底部菜单栏（大面板）
    OhGlass.register(GlassIds.BOTTOM_BAR, OhGlassKind.PANEL, BOTTOM_BAR_RADIUS_VP);
    OhGlass.registerCapsule(GlassIds.TOP_BACK, OhGlassKind.CAPSULE);
    OhGlass.registerCapsule(GlassIds.TOP_TOC, OhGlassKind.CAPSULE);
    const registrar: FontRegistrar = {
      registerFont: (familyName: string, familySrc: string): void => {
        try {
          this.getUIContext().getFont().registerFont({
            familyName: familyName,
            familySrc: familySrc
          });
        } catch (e) {
        }
      }
    };
    this.engine.setFontRegistrar(registrar);
    this.currentThemeId = this.engine.getThemeManager().currentTheme.id;
    this.initEngine();
    this.startStatusTimer();
    this.batteryMonitor.onBatteryChange((charging: boolean, soc: number): void => {
      if (this.pageDestroyed) {
        return;
      }
      this.batteryCharging = charging;
      this.batterySoc = soc;
    });
    this.batteryMonitor.setDestroyed(false);
    this.batteryMonitor.start();
  }

  aboutToDisappear(): void {
    this.pageDestroyed = true;
    this.stopAutoTurn();
    this.cancelControlsAutoHide();
    this.batteryMonitor.setDestroyed(true);
    this.batteryMonitor.stop();
    if (this.statusTimer > 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    if (this.mainWindow !== null) {
      try {
        this.mainWindow.off('windowSizeChange', this.onWindowSizeChangeCb);
      } catch (e) {
      }
      // 退出阅读器：恢复系统栏 + 退出全屏布局（避免影响其他页面）
      this.restoreSystemBar();
      this.mainWindow = null;
    }
    this.pageRenderer.dispose();
    this.flipController.dispose();
    this.slideController.dispose();
    // 液态玻璃：停止形变循环 + 释放 EGL/GL 资源 + 清空登记
    OhGlass.dispose();
    // P0-B: Session 关闭闭环——销毁引擎（停止后台 reflow/prefetch/timer/listener，
    // 释放 TxtDocument fd 与内存缓存；幂等防抖，退出书后不再占用 CPU/IO）。
    this.disposeEngine();
  }

  /** P0-B/P0-D: 引擎 Session 销毁（幂等；aboutToDisappear 唯一入口）。
   *  顺序：先 flush 阅读位置（canonical owner=PageManager），再 destroy。 */
  private disposeEngine(): void {
    if (this.engineDestroyed) {
      return;
    }
    this.engineDestroyed = true;
    try {
      hilog.info(0x0000, READER_TAG, 'READING_POSITION_FLUSH page=%{public}d gen=%{public}d',
        this.engine.getGlobalPageNumber(), this.engine.getPageGeneration());
      this.engine.destroy();
    } catch (_e) {
    }
  }

  /** 恢复阅读器设置并应用（字号/行距/对齐/翻页方式/页码显示） */
  private async restoreSettings(): Promise<void> {
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      return;
    }
    const settings: ReaderSettings = new ReaderSettings();
    const loaded = await settings.load(hostCtx);
    if (this.pageDestroyed) {
      return;
    }
    this.turnMode = loaded.turnMode;
    this.singleHand = loaded.singleHand;
    this.eyeTracking = loaded.eyeTracking;
    this.pageNumberMode = loaded.pageNumberMode;
    this.autoSpeed = loaded.autoSpeed;
    this.textAlignMode = loaded.textAlign;
    this.fontSizeLevel = loaded.fontSizeLevel;
    this.lineSpacingLevel = loaded.lineSpacingLevel;
    this.applyFontSizeLevel(loaded.fontSizeLevel, false);
    this.applyLineSpacingLevel(loaded.lineSpacingLevel, false);
    this.applyTextAlign(loaded.textAlign, false);
  }

  private async persistSettings(): Promise<void> {
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      return;
    }
    const settings: ReaderSettings = new ReaderSettings();
    await settings.save(hostCtx, {
      turnMode: this.turnMode,
      singleHand: this.singleHand,
      eyeTracking: this.eyeTracking,
      pageNumberMode: this.pageNumberMode,
      autoSpeed: this.autoSpeed,
      textAlign: this.textAlignMode,
      fontSizeLevel: this.fontSizeLevel,
      lineSpacingLevel: this.lineSpacingLevel
    });
  }

  /**
   * Phase 11.1: open 前排版参数预置（Anchor-first）。
   * 在 engine.open 之前把持久化字号/行距/对齐应用到引擎（不触发 reflow/invalidate），
   * 使 open 时 layout signature 与磁盘 L2/L3 一致 → 缓存可复用、冷启动无全书同步 reflow。
   * 同时预记字段，使后续 restoreSettings 的各 apply* 等值短路（不再重放 reflow）。
   */
  private async preflightTypography(ctx: Context): Promise<void> {
    const settings: ReaderSettings = new ReaderSettings();
    const loaded = await settings.load(ctx);
    if (this.pageDestroyed) {
      return;
    }
    this.turnMode = loaded.turnMode;
    this.singleHand = loaded.singleHand;
    this.textAlignMode = loaded.textAlign;
    this.fontSizeLevel = loaded.fontSizeLevel;
    this.lineSpacingLevel = loaded.lineSpacingLevel;
    const fsClamped: number = Math.max(1, Math.min(FONT_SIZE_LEVELS.length, loaded.fontSizeLevel));
    const lsClamped: number = Math.max(1, Math.min(LINE_SPACING_LEVELS.length, loaded.lineSpacingLevel));
    const size: number = FONT_SIZE_LEVELS[fsClamped - 1];
    const spacing: number = LINE_SPACING_LEVELS[lsClamped - 1];
    const align: 'left' | 'right' | 'justify' | undefined =
      (loaded.textAlign === 'left' || loaded.textAlign === 'right' || loaded.textAlign === 'justify')
        ? loaded.textAlign
        : undefined;
    this.engine.prepareOpenTypography({ fontSize: size, lineSpacing: spacing, textAlign: align });
  }

  /** Phase 11.3: pageReady 监听（先于 open 注册；发行不再丢失） */
  private registerPageReadyListener(): void {
    if (this.pageReadyRegistered) {
      return;
    }
    this.pageReadyRegistered = true;
    this.engine.paramBus.onChange('pageReady', () => {
      if (this.pageDestroyed) {
        return;
      }
      this.currentPageNum = this.engine.getDocumentPageNumber();
      this.totalPages = this.engine.getTotalPages();
      this.updateChapterPageInfo();
      this.refreshPage();
    });
  }

  private async initEngine(): Promise<void> {
    // P0-B: 单飞行（快速重入/重复回调不创建第二个 Engine，不重复初始化）
    if (this.initInFlight !== null) {
      return this.initInFlight;
    }
    const flight: Promise<void> = this.doInitEngine();
    this.initInFlight = flight;
    try {
      await flight;
    } finally {
      if (this.initInFlight === flight) {
        this.initInFlight = null;
      }
    }
  }

  private async doInitEngine(): Promise<void> {
    if (this.pageDestroyed) {
      return;
    }
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      this.errorMsg = '获取应用上下文失败';
      this.engineState = '错误';
      return;
    }
    const ctx: Context = hostCtx;
    hilog.info(0x0000, READER_TAG, 'SESSION_INIT_START');
    try {
      const viewportOk: boolean = await this.prepareWindowAndViewport(ctx);
      if (!viewportOk) {
        return;
      }
      const src: BookSource | undefined = await this.resolveBookSource(ctx);
      if (this.pageDestroyed || src === undefined) {
        return;
      }
      // Phase 11: pageReady 监听先于 open 注册（open 期间/之前的发行不再丢失）。
      this.registerPageReadyListener();
      // Phase 11.1: Anchor-first —— open 前应用持久化排版参数（等值短路，
      // 消除「字号恢复 → 全书同步 reflow」；featureFlags.anchorFirst 关闭时走旧路径）。
      if (this.featureFlags.anchorFirst) {
        await this.preflightTypography(ctx);
      }
      await this.openAndLoad(ctx, src);
      await this.setupThemeAndListeners(ctx);
      if (!this.pageDestroyed) {
        hilog.info(0x0000, READER_TAG, 'SESSION_INIT_SUCCESS');
      }
    } catch (e) {
      if (!this.pageDestroyed) {
        this.errorMsg = '引擎初始化失败: ' + (e instanceof Error ? e.message : JSON.stringify(e));
        this.engineState = '错误';
        hilog.info(0x0000, READER_TAG, 'SESSION_INIT_FAIL err=%{public}s', String(e));
      }
    }
  }

  /** 引擎初始化①：窗口/显示尺寸捕获 → 引擎视口配置（失败返回 false） */
  private async prepareWindowAndViewport(ctx: Context): Promise<boolean> {
    let mainWindow: window.Window;
    let sysAvoid: window.AvoidArea;
    let navAvoid: window.AvoidArea;
    let winRect: window.Rect;
    let density: number;
    try {
      mainWindow = await window.getLastWindow(ctx);
      if (this.pageDestroyed) {
        return false;
      }
      sysAvoid = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      navAvoid = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      winRect = mainWindow.getWindowProperties().windowRect;
      const defaultDisplay = display.getDefaultDisplaySync();
      density = defaultDisplay.densityPixels;
    } catch (e) {
      this.errorMsg = '获取窗口/显示信息失败: ' + (e instanceof Error ? e.message : String(e));
      this.engineState = '错误';
      return false;
    }
    const avoidAreaTop: number = sysAvoid.topRect.height;
    const avoidAreaBottom: number = sysAvoid.bottomRect.height + navAvoid.bottomRect.height;
    this.screenDensity = density;
    this.pageRenderer.setScreenDensity(density);
    const viewWidthVp: number = Math.round(winRect.width / density);
    const rawH: number = Math.round((winRect.height - avoidAreaTop - avoidAreaBottom) / density);
    const defaultMargins = this.engine.getMargins();
    let marginL: number = defaultMargins.left;
    let marginR: number = defaultMargins.right;
    // 平板 / 大屏（横竖屏）：按屏宽放大左右边距，限制正文行宽（居中），提升可读性
    if (viewWidthVp >= 600) {
      const sidePad: number = Math.min(Math.max(64, Math.round(viewWidthVp * 0.07)), 150);
      marginL = sidePad;
      marginR = sidePad;
    }
    this.margins = { left: marginL, right: marginR, top: defaultMargins.top, bottom: defaultMargins.bottom } as Margins;
    const contentW: number = viewWidthVp - this.margins.left - this.margins.right;
    const contentH: number = rawH - this.margins.top - this.margins.bottom;
    this.engine.configure({
      viewWidth: contentW, viewHeight: contentH, density: density
    });
    this.mainWindow = mainWindow;
    mainWindow.on('windowSizeChange', this.onWindowSizeChangeCb);
    // 沉浸式：隐藏状态栏/导航条（异步，避让区在回调中刷新）
    this.enableImmersive(mainWindow);
    this.contentWidth = contentW;
    this.contentHeight = contentH;
    this.canvasW = viewWidthVp;
    this.canvasH = Math.round(winRect.height / density);
    this.avoidAreaBottom = Math.round((sysAvoid.bottomRect.height + navAvoid.bottomRect.height) / density);
    this.avoidAreaTopVp = Math.round(sysAvoid.topRect.height / density);
    return true;
  }

  /** 引擎初始化②：书籍来源准备（统一导入入口：接入 / 解压 / 解析 / 落盘） */
  private async resolveBookSource(ctx: Context): Promise<BookSource | undefined> {
    if (this.bookPath.length === 0) {
      this.errorMsg = '未指定书籍路径（bookPath 为空）';
      this.engineState = '错误';
      return undefined;
    }
    const lowerPath: string = this.bookPath.toLowerCase();
    if (lowerPath.endsWith('.pdf')) {
      this.errorMsg = 'PDF 暂不支持（当前仅 EPUB / TXT）';
      this.engineState = '错误';
      return undefined;
    }
    // Phase 6: 磁盘配额（全局 LRU + per-book cap）。在每次打开书籍前执行，
    // 超配时淘汰最久未访问的"可重建缓存"目录（L2/L1 副本），不删源书。
    const quota: DiskCacheQuotaManager = new DiskCacheQuotaManager();
    quota.enforceGlobalQuota(ctx.filesDir);
    // 统一导入入口（FR-012）：接入源文件 +（EPUB/CBZ）解压 + 解析 + 落盘。
    // 已导入（台账命中且产物有效）→ ALREADY_IMPORTED，直接热启动，不重复解压/解析。
    this.engineState = '导入/解析书籍...';
    const request: ImportRequest = { sourcePath: this.bookPath };
    let result: ImportResult = { status: ImportStatus.FAILED, bookId: '', error: '导入未执行' };
    try {
      result = await ImportService.importBook(ctx.filesDir, request, (stage: string): void => {
        if (!this.pageDestroyed) {
          this.engineState = '导入中: ' + stage;
        }
      });
    } catch (e) {
      this.errorMsg = '导入失败：' + (e instanceof Error ? e.message : String(e));
      this.engineState = '错误';
      return undefined;
    }
    if (this.pageDestroyed) {
      return undefined;
    }
    if (result.status !== ImportStatus.SUCCESS && result.status !== ImportStatus.ALREADY_IMPORTED) {
      this.errorMsg = result.error !== undefined ? result.error : '导入失败';
      this.engineState = '错误';
      return undefined;
    }
    const rec: ImportedBook | undefined = result.record;
    if (rec === undefined) {
      this.errorMsg = '导入结果缺少台账记录';
      this.engineState = '错误';
      return undefined;
    }
    const bookBasePath: string = rec.extractDir.length > 0 ? rec.extractDir : rec.sourcePath;
    this.pageRenderer.setBookBasePath(bookBasePath);
    return {
      sourcePath: rec.sourcePath,
      bookBasePath: bookBasePath,
      cacheDir: rec.cacheDir,
      libraryDir: rec.libraryDir
    };
  }

  /** 引擎初始化③：打开书籍 + 首页/批注/书签装载（消费 ImportService 输出） */
  private async openAndLoad(ctx: Context, src: BookSource): Promise<void> {
    this.engineState = '打开书籍...';
    const pageCacheDir: string = src.cacheDir;
    try { fileIo.mkdirSync(pageCacheDir, true); } catch (_e) { }
    // Phase 1 (L1): 阅读状态独立目录（不随 L2 缓存失效，跨改动持久化）
    const readingStateDir: string = ctx.filesDir + '/reading_state';
    // 阶段1：持久目录（导入成果，如 TXT 索引），不受 cache 清理/配额/迁移影响
    const libraryDir: string = src.libraryDir;
    const pub = await this.engine.open(src.bookBasePath,
      {
        sourcePath: src.sourcePath.length > 0 ? src.sourcePath : undefined,
        cacheDir: pageCacheDir,
        readingStateDir: readingStateDir,
        libraryDir: libraryDir
      });
    // Phase 7 ImportCheckpoint: open 返回即 PARSE 完成；热窗分页落盘后 CACHE_DONE。
    // PARSE 未可靠提交（open 抛错）时上层走异常路径，不标记——下一轮整段重做。
    if (src.bookBasePath.length > 0) {
      ImportCheckpoint.markStage(src.bookBasePath, ImportStage.PARSE_DONE);
      ImportCheckpoint.markStage(src.bookBasePath, ImportStage.CACHE_DONE);
    }
    this.engineState = '已加载: ' + (pub !== undefined ? pub.getMetadata().title : '未知标题');
    this.engine.initDictionaryConfigManager(ctx.filesDir);

    const page = this.engine.getCurrentPage();
    if (page !== undefined) {
      this.pageLines = page.lines;
    } else {
      this.pageLines = [];
    }
    // Phase 24/25：页码必须与 totalPages 同空间（文档空间）。getGlobalPageNumber
    // 是槽空间（未物化章压缩为 1 槽），冷开时会把「封面/末章」显示成 31 而非真实
    // 文档位；pgcount 命中后 getDocumentPageNumber 可即时给出精确文档页码。
    this.currentPageNum = this.engine.getDocumentPageNumber();
    this.totalPages = this.engine.getTotalPages();
    this.updateChapterPageInfo();
    // Phase 25 观测：打开即总页数（pgcount 命中时应为真实页数，如 318）
    hilog.info(0x0000, READER_TAG, 'OPEN_TOTAL page=%{public}d total=%{public}d',
      this.currentPageNum, this.totalPages);
    this.pageRenderer.renderPage();
    // Phase 11: 冷启动首帧 + 后台增量 reflow 启动（Anchor-first；首帧早于全书 reflow 完成）
    if (this.featureFlags.anchorFirst) {
      hilog.info(0x0000, READER_TAG,
        'COLDSTART FIRST_FRAME page=%{public}d gen=%{public}d %{public}s',
        this.engine.getGlobalPageNumber(), this.engine.getPageGeneration(),
        this.engine.describeNeighborWindow());
      this.engine.scheduleBackgroundReflow();
    }
    if (this.featureFlags.annotations || this.featureFlags.bookmarks) {
      await this.engine.getAnnotationStorage().init(ctx);
      // 加载书签
      this.bookmarkStorage = new BookmarkStorage();
      await this.bookmarkStorage.init(ctx);
      const pub2 = this.engine.getPublication();
      if (pub2 !== undefined) {
        const bookId: string = pub2.getMetadata().title;
        this.annotations = await this.engine.getAnnotationStorage().getAll(bookId);
        this.bookmarks = await this.bookmarkStorage.getAll(bookId);
        this.engine.syncAnnotations(this.annotations);
      }
    }
  }

  /** 引擎初始化④：主题监听 / 恢复 + 字号·pageReady 监听 + 阅读设置恢复 */
  private async setupThemeAndListeners(ctx: Context): Promise<void> {
    // 注册主题变化监听 → 重绘
    this.engine.getThemeManager().onThemeChange((t: Theme) => {
      if (this.pageDestroyed) {
        return;
      }
      this.currentThemeId = t.id;
      this.engine.mediaContext.colorScheme = t.id === 'night' ? 'dark' : 'light';
      try {
        // 仅重编译主题颜色并重绘当前页，不触发重新排版/重分页
        this.engine.applyThemeCss();
        this.refreshPage();
      } catch (e) {
      }
      this.syncSystemBarContentColor(t.id);
    });
    // 恢复主题
    const savedTheme: string = await new ThemePreferenceStorage().load(ctx);
    if (this.pageDestroyed) {
      return;
    }
    this.engine.getThemeManager().switchTheme(savedTheme);
    // 字号变化刷新页码
    this.engine.paramBus.onChange('fontSize', () => {
      if (this.pageDestroyed) {
        return;
      }
      this.currentPageNum = this.engine.getDocumentPageNumber();
      this.totalPages = this.engine.getTotalPages();
      this.updateChapterPageInfo();
    });
    // Phase 11.3: pageReady 已在 open 前注册（registerPageReadyListener），此处不再重复注册
    // 引擎就绪后应用已保存的阅读设置（字号/行距/对齐/翻页方式等）
    await this.restoreSettings();
  }

  private syncSystemBarContentColor(themeId: string): void {
    ReaderThemeUtils.syncSystemBarColor(themeId, this.getUIContext().getHostContext());
  }

  /** 打开目录 / 笔记弹窗（自定义弹窗 CustomDialog，不使用沉浸光感） */
  private openTocDialog(): void {
    this.tocDialogController = new CustomDialogController({
      builder: TocPanel({
        toc: this.engine.getTableOfContents(),
        bookmarkChapters: this.bookmarkChapterSet(),
        noteChapters: this.noteChapterSet(),
        notes: this.annotations,
        tocChapterIndices: this.tocChapterIndices(),
        pageNumbers: this.tocPageNumbers(),
        currentPageNum: this.currentPageNum,
        bookTitle: this.currentBookTitle(),
        coverPath: this.resolvedCoverPath(),
        isCurrent: (item: TocItem) => this.isCurrentTocItem(item),
        currentChapterIndex: this.engine.getCurrentChapterIndex(),
        isDark: readerIsDark(),
        avoidAreaTopVp: this.avoidAreaTopVp,
        avoidAreaBottom: this.avoidAreaBottom,
        contentWidth: this.contentWidth,
        canvasH: this.canvasH,
        margins: this.margins,
        onClose: () => {
          this.closeTocDialog();
        },
        onSelect: (item: TocItem) => {
          this.engine.goToTocItem(item);
          this.refreshPage();
          this.closeTocDialog();
          this.hideControls();
        },
        onSelectAnnotation: (ann: Annotation) => {
          this.engine.goToAnnotation(ann);
          this.refreshPage();
          this.closeTocDialog();
          this.hideControls();
        }
      }),
      autoCancel: true,
      // TocPanel 自绘完整卡片（白底/圆角/阴影），禁用默认弹窗容器样式
      customStyle: true,
      systemMaterial: MaterialConfig.sheetMaterial(),
      // 返回 / ESC / 点击遮罩关闭：弹窗为模态，本控制器会在关闭后失效，仅清理引用
      cancel: () => {
        this.tocDialogController = null;
      }
    });
    this.tocDialogController.open();
  }

  /** 关闭目录弹窗（幂等） */
  private closeTocDialog(): void {
    if (this.tocDialogController !== null) {
      const ctrl: CustomDialogController = this.tocDialogController;
      this.tocDialogController = null;
      ctrl.close();
    }
  }

  /** 设置半模态高度 */
  private settingsSheetHeight(): number {
    const topInset: number = this.avoidAreaTopVp + 60;
    const h: number = this.canvasH - topInset - this.avoidAreaBottom - ControlSpec.BOTTOM_SAFE - ControlSpec.FUNC_ROW_H;
    return Math.max(320, Math.min(680, h));
  }

  /** 设置面板（bindSheet 半模态：弹窗类接口全区域生效） */
  @Builder
  settingsSheet() {
    ReaderSettingsPanel({
      singleHand: this.singleHand,
      featureFlags: this.featureFlags,
      autoSpeed: this.autoSpeed,
      autoTurning: this.autoTurning,
      pageNumberMode: this.pageNumberMode,
      margins: this.margins,
      avoidAreaBottom: this.avoidAreaBottom,
      contentWidth: this.contentWidth,
      canvasH: this.canvasH,
      onSingleHandChange: (v: boolean) => {
        this.singleHand = v;
        this.persistSettings();
      },
      onAutoSpeedChange: (v: number) => {
        this.autoSpeed = v;
        this.persistSettings();
        this.restartAutoTurnTimer();
      },
      onStartAutoTurn: () => {
        hilog.info(0x0000, READER_TAG, 'onStartAutoTurn callback fired');
        this.showSettings = false;
        this.startAutoTurn();
      },
      onExitAutoTurn: () => {
        hilog.info(0x0000, READER_TAG, 'onExitAutoTurn callback fired');
        this.showSettings = false;
        this.stopAutoTurn();
      },
      onPageNumberModeChange: (mode: ReaderPageNumberMode) => {
        this.pageNumberMode = mode;
        this.persistSettings();
      },
      onOpenVocabulary: () => {
        this.showSettings = false;
        if (this.onOpenVocabulary !== undefined) {
          this.onOpenVocabulary(this.engine);
        } else {
          this.showPlaceholderToast('词汇表页未接入');
        }
      },
      onToggleAnnotationPanel: () => {
        this.showSettings = false;
        this.showAnnotationPanel = true;
      },
      onExportAnnotations: () => {
        this.showSettings = false;
        this.exportAnnotations('markdown');
      },
      onOpenApiConfig: () => {
        this.showSettings = false;
        this.showApiConfig = true;
      },
      onToggleListen: () => {
        this.showPlaceholderToast('听书（占位）');
      },
      onClose: () => {
        this.showSettings = false;
      }
    })
  }

  build() {
    Stack() {
      // ===== ① 背景内容层（会被截图给玻璃做底，顺序不能变） =====
      Stack() {
      // ===== 内容层（Canvas） =====
      if (this.errorMsg.length > 0) {
        Text(this.engineState).fontSize(14).fontColor('#ff4444')
        Text(this.errorMsg).fontSize(12).fontColor('#ff4444').margin({ top: 8 })
      } else {
        Canvas(this.canvasCtx)
          .width(this.canvasW)
          .height(this.canvasH)
          .onReady(() => {
            this.pageRenderer.renderPage();
          })
          .onTouch((event: TouchEvent) => {
            this.gestureController.handleTouch(event);
            // 页面交互视为一次操作：控制层显示中则重置 10s 自动隐藏计时
            if (this.showControls) {
              this.onControlsInteraction();
            }
          })
          .position({ x: 0, y: 0 })
      }

      // ===== 顶部渐变遮罩（刘海/状态栏区域）：顶部不透明 → 向下渐隐；
      // 颜色仅由深浅色模式决定（浅色=白 / 深色=黑），与阅读背景无关 =====
      if (this.errorMsg.length === 0) {
        Column()
          .width('100%')
          .height(150)
          .linearGradient({
            angle: 180,
            colors: readerIsDark()
              ? [['#59000000', 0.0], ['#00000000', 1.0]]
              : [['#59FFFFFF', 0.0], ['#00000000', 1.0]]
          })
          .position({ x: 0, y: 0 })
          .hitTestBehavior(HitTestMode.None)
      }

      // ===== 底部渐变遮罩（底部导航条区域）：底部不透明 → 向上渐隐，常驻；
      // 颜色仅由深浅色模式决定（浅色=白 / 深色=黑），与阅读背景无关 =====
      if (this.errorMsg.length === 0) {
        Column()
          .width('100%')
          .height(200)
          .linearGradient({
            angle: 180,
            colors: readerIsDark()
              ? [['#00000000', 0.0], ['#59000000', 1.0]]
              : [['#00000000', 0.0], ['#59FFFFFF', 1.0]]
          })
          .position({ x: 0, bottom: 0 })
          .hitTestBehavior(HitTestMode.None)
      }

      // ===== 常驻状态条（时间/电量/页数） =====
      if (this.errorMsg.length === 0) {
        ReaderStatusBar({
          timeText: this.timeText,
          batteryCharging: this.batteryCharging,
          batterySoc: this.batterySoc,
          pageRightText: this.pageNumberText(),
          margins: this.margins,
          avoidAreaBottom: this.avoidAreaBottom,
          contentWidth: this.contentWidth,
          canvasH: this.canvasH
        })
      }
      }
      .id(OhGlass.CONTENT_ID)
      .width('100%')
      .height('100%')

      // ===== ② 唯一的全屏 GL surface：所有玻璃都在这里画 =====
      OhGlassSurface()

      // ===== ③ 已有组件盖在玻璃之上（透明背景 + .id 即获得玻璃） =====
      // ===== 长按选词弹窗 =====
      if (this.selection !== null) {
        SelectionContextMenu({
          selection: this.selection,
          showTranslate: this.showTranslate,
          showDictionary: this.showDictionary,
          annotationsEnabled: this.featureFlags.annotations,
          anchorX: this.selectionMenuX,
          anchorY: this.selectionMenuY,
          margins: this.margins,
          canvasW: this.canvasW,
          canvasH: this.canvasH,
          onCopy: (text: string) => {
            ContextMenuManager.copyToClipboard(text);
            this.clearSelection();
          },
          onNote: (text: string) => {
            this.addAnnotationFromSelection(AnnotationType.NOTE, text);
          },
          onUnderline: () => {
            this.addAnnotationFromSelection(AnnotationType.UNDERLINE);
          },
          onTranslate: (text: string) => {
            this.showPlaceholderToast('翻译（占位）：' + text);
            this.clearSelection();
          },
          onDictionary: (text: string) => {
            this.selection = null;
            this.pageRenderer.renderPage();
            this.lookupDialogController = new CustomDialogController({
              builder: WordLookupDialog({
                word: text,
                sentence: '',
                engine: this.engine
              }),
              autoCancel: true,
              systemMaterial: MaterialConfig.sheetMaterial()
            });
            this.lookupDialogController.open();
          },
          onShare: (text: string) => {
            const uiContext: UIContext = this.getUIContext();
            ContextMenuManager.shareText(text, uiContext);
            this.clearSelection();
          },
          onHighlight: () => {
            this.addAnnotationFromSelection(AnnotationType.HIGHLIGHT);
          }
        })
      }

      // ===== 顶部控制栏（返回 + 目录）：仅两个裸玻璃按钮，沉浸光感 =====
      // 恢复自备份：ReaderTopBar 两个圆形系统材质按钮，其余区域穿透到下方画布
      if (this.showControls) {
        ReaderTopBar({
          isDark: this.currentThemeId === 'night' || readerIsDark(),
          margins: this.margins,
          avoidAreaTopVp: this.avoidAreaTopVp,
          contentWidth: this.contentWidth,
          onBack: () => {
            this.getUIContext().getRouter().back();
          },
          onToggleToc: () => {
            this.openTocDialog();
          },
          onTapOutside: () => {
            this.hideControls();
          }
        })
      }

      // ===== 底部控制面板（纯悬浮胶囊式）=====
      if (this.showControls) {
        ReaderControlPanel({
          progress: this.currentProgress(),
          fontSizeLevel: this.fontSizeLevel,
          lineSpacingLevel: this.lineSpacingLevel,
          textAlign: this.textAlignMode,
          turnMode: this.turnMode,
          singleHand: this.singleHand,
          topStatusBarResident: this.topStatusBarResident,
          currentFontFamily: this.engine.getFontThemeManager().currentTheme.cjkFontFamily ?? '',
          themes: PRESET_THEMES,
          currentThemeId: $currentThemeId,
          barMode: this.barMode,
          margins: this.margins,
          avoidAreaBottom: this.avoidAreaBottom,
          contentWidth: this.contentWidth,
          canvasH: this.canvasH,
          onProgressChange: (v: number) => {
            this.goToProgress(v);
          },
          onQuerySeekInfo: (v: number): SeekInfo => {
            return this.querySeekInfo(v);
          },
          onPrevPage: () => {
            this.turnPageBy(TurnDirection.BACKWARD);
          },
          onNextPage: () => {
            this.turnPageBy(TurnDirection.FORWARD);
          },
          onFontSizeLevelChange: (level: number) => {
            this.applyFontSizeLevel(level, true);
          },
          onLineSpacingLevelChange: (level: number) => {
            this.applyLineSpacingLevel(level, true);
          },
          onTextAlignChange: (align: ReaderTextAlign) => {
            this.applyTextAlign(align, true);
          },
          onTurnModeChange: (mode: ReaderTurnMode) => {
            this.turnMode = mode;
            this.persistSettings();
          },
          onSelectFont: (family: string) => {
            this.applyFontFamily(family);
          },
          onSelectTheme: (id: string) => {
            this.engine.getThemeManager().switchTheme(id);
            this.currentThemeId = id;
            this.saveThemePreference(id);
          },
          onToggleTheme: () => {
            try {
              const targetId: string = ReaderThemeUtils.nextId(this.engine.getThemeManager().currentTheme.id);
              this.engine.getThemeManager().switchTheme(targetId);
              // 直接同步本地状态：无论主题监听回调时序如何，立即驱动菜单栏刷新
              this.currentThemeId = targetId;
              this.saveThemePreference(targetId);
            } catch (e) {
              // 主题切换失败不影响按钮状态与阅读器使用
            }
          },
          onSingleHandChange: (v: boolean) => {
            this.singleHand = v;
            this.persistSettings();
          },
          onOpenSettings: () => {
            // 设置作为遮罩层叠于底部菜单之上，不隐藏菜单
            this.showSettings = true;
          },
          onUserInteraction: () => {
            this.onControlsInteraction();
          },
          onPanelVisibilityChange: (visible: boolean) => {
            this.quickPanelOpen = visible;
            if (visible) {
              this.cancelControlsAutoHide();
            } else {
              this.scheduleControlsAutoHide();
            }
          },
          onTopStatusBarResidentChange: (enabled: boolean) => {
            this.topStatusBarResident = enabled;
            if (enabled) {
              this.setStatusBarVisible(true);
            } else if (!this.showControls) {
              this.setStatusBarVisible(false);
            }
          }
        })
      }

      // ===== 阅读设置面板（bindSheet 半模态 + SheetOptions.systemMaterial）=====
      // API26 生效约束：设置入口在底栏普通位置，普通组件材质不渲染；
      // 半模态转场属弹窗类接口全区域生效，设置面板整体以 Sheet 承载获得真材质。
      Column() {
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
      .bindSheet($$this.showSettings, this.settingsSheet(), {
        height: this.settingsSheetHeight(),
        mode: SheetMode.OVERLAY,
        showClose: false,
        systemMaterial: MaterialConfig.sheetMaterial()
      })

      // ===== 自动翻页控制栏 =====
      if (this.showAutoTurnBar) {
        AutoTurnBar({
          autoSpeed: this.autoSpeed,
          margins: this.margins,
          avoidAreaBottom: this.avoidAreaBottom,
          contentWidth: this.contentWidth,
          canvasH: this.canvasH,
          onAutoSpeedChange: (v: number) => {
            this.autoSpeed = v;
            this.persistSettings();
            this.restartAutoTurnTimer();
          },
          onResume: () => {
            // 关闭控制栏 = 继续自动翻页
            this.showAutoTurnBar = false;
            this.startAutoTurnTimer();
          },
          onExit: () => {
            this.stopAutoTurn();
          }
        })
      }

      // ===== 目录 / 笔记弹窗（CustomDialog 自定义弹窗 + options.systemMaterial）=====
      // API26 生效约束：弹窗类组件全区域生效，材质经 CustomDialogController
      // 的 systemMaterial 配置；打开/关闭见 openTocDialog()/closeTocDialog()。

      // ===== 在线词典 API 设置弹窗（独立居中卡片） =====
      if (this.showApiConfig) {
        ApiConfigPanel({
          apiConfigName: this.apiConfigName,
          apiConfigEndpoint: this.apiConfigEndpoint,
          apiConfigMessage: this.apiConfigMessage,
          onNameChange: (val: string) => { this.apiConfigName = val; },
          onEndpointChange: (val: string) => { this.apiConfigEndpoint = val; },
          onAdd: () => {
            const endpoint: string = this.apiConfigEndpoint.trim();
            const name: string = this.apiConfigName.trim();
            if (name.length === 0) {
              this.apiConfigMessage = '请填写 API 名称';
              return;
            }
            if (endpoint.length === 0) {
              this.apiConfigMessage = '请填写端点 URL';
              return;
            }
            if (!endpoint.startsWith('https://')) {
              this.apiConfigMessage = '端点必须是 https:// 开头的 URL';
              return;
            }
            if (endpoint.indexOf('{word}') < 0) {
              this.apiConfigMessage = '端点必须包含 {word} 占位符';
              return;
            }
            this.engine.addCustomDictionary(name, endpoint);
            this.apiConfigMessage = '已添加: ' + name;
            this.apiConfigName = '';
            this.apiConfigEndpoint = '';
          },
          onClose: () => {
            this.showApiConfig = false;
            this.apiConfigMessage = '';
          }
        })
      }

      // ===== 标注面板 =====
      if (this.showAnnotationPanel) {
        AnnotationPanel({
          annotations: this.annotations,
          onDelete: (ann: Annotation) => {
            const pub3 = this.engine.getPublication();
            if (pub3 === undefined) return;
            const bookId2: string = pub3.getMetadata().title;
            this.engine.getAnnotationStorage().remove(bookId2, ann.id);
            const idx: number = this.annotations.indexOf(ann);
            if (idx >= 0) {
              this.annotations.splice(idx, 1);
            }
            this.engine.syncAnnotations(this.annotations);
            this.pageRenderer.renderPage();
          },
          onExport: (format: string) => {
            this.exportAnnotations(format);
          },
          onClose: () => {
            this.showAnnotationPanel = false;
          }
        })
      }
    }
    .width('100%').height('100%')
    // 布局变化 → 重算玻璃矩形（组件侧不需要任何回调）
    .onAreaChange(() => {
      OhGlass.refresh();
    })
    // 音量键翻页：聚焦根组件接收按键，转交手势控制器统一处理
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      if (this.pageDestroyed) {
        return;
      }
      this.gestureController.handleVolumeKeyEvent(event.keyCode, event.type === KeyType.Down);
    })
  }

  // ==================== 状态条 / 章节页数 ====================

  private startStatusTimer(): void {
    if (this.statusTimer > 0) {
      clearInterval(this.statusTimer);
    }
    this.timeText = formatClock();
    this.statusTimer = setInterval(() => {
      if (this.pageDestroyed) {
        return;
      }
      this.timeText = formatClock();
      // 电量由系统电池事件实时驱动，定时器仅作低频兜底同步
      this.batteryCharging = readCharging();
      this.batterySoc = readSoc();
    }, 15000);
  }

  private updateChapterPageInfo(): void {
    const cp = ReaderInfo.chapterPages(this.engine);
    this.chapterTotalPages = cp.total;
    this.chapterCurrentPage = cp.current;
  }

  /** 页码显示文本（章节页数 / 总页数 / 进度百分比 三种模式） */
  private pageNumberText(): string {
    return ReaderInfo.pageNumberText(this.pageNumberMode, this.chapterCurrentPage,
      this.chapterTotalPages, this.currentPageNum, this.totalPages);
  }

  private currentProgress(): number {
    return ReaderInfo.progress(this.currentPageNum, this.totalPages);
  }

  // ==================== 阅读设置应用 ====================

  private applyFontSizeLevel(level: number, persist: boolean): void {
    const clamped: number = Math.max(1, Math.min(FONT_SIZE_LEVELS.length, level));
    this.fontSizeLevel = clamped;
    const size: number = FONT_SIZE_LEVELS[clamped - 1];
    // Phase 11: 等值短路——已应用相同字号（open 前 prepareOpenTypography 已设置）时不重放全书 reflow
    if (this.engine.getFontSizeController().userFontSize !== size) {
      this.engine.getFontSizeController().setUserFontSize(size);
      this.engine.getFontSizeController().applyUserFontSize();
    }
    this.refreshPage();
    if (persist) {
      this.persistSettings();
    }
  }

  private applyLineSpacingLevel(level: number, persist: boolean): void {
    const clamped: number = Math.max(1, Math.min(LINE_SPACING_LEVELS.length, level));
    this.lineSpacingLevel = clamped;
    const spacing: number = LINE_SPACING_LEVELS[clamped - 1];
    // Phase 11: 等值短路——行距未变化时不触发 setLayoutProfile → reflowAllChapters
    if (this.engine.getLayoutProfile().lineSpacing !== spacing) {
      this.engine.setLayoutProfile({ lineSpacing: spacing });
    }
    this.refreshPage();
    if (persist) {
      this.persistSettings();
    }
  }

  private applyTextAlign(align: ReaderTextAlign, persist: boolean): void {
    this.textAlignMode = align;
    // 'auto'：不覆盖布局对齐（沿用引擎/书本默认排版），其余直通 LayoutProfile
    if (align === 'left' || align === 'right' || align === 'justify' || align === 'center') {
      // Phase 11: 等值短路——对齐未变化时不触发 setLayoutProfile → reflowAllChapters
      if (this.engine.getLayoutProfile().textAlign !== align) {
        this.engine.setLayoutProfile({ textAlign: align });
      }
    }
    this.refreshPage();
    if (persist) {
      this.persistSettings();
    }
  }

  /** 跳转到全局进度 */
  private goToProgress(v: number): void {
    // P0-C: 导航态立即更新（页码指示不依赖目标页就绪）
    const ok: boolean = this.engine.goToProgress(v);
    if (ok) {
      this.currentPageNum = this.engine.getDocumentPageNumber();
      this.totalPages = this.engine.getTotalPages();
      this.updateChapterPageInfo();
      const cur: PageSlot | undefined = this.engine.getCurrentPage();
      hilog.info(0x0000, READER_TAG,
        'JUMP_REQUEST target=%{public}d ready=%{public}d gen=%{public}d',
        this.currentPageNum, cur !== undefined && cur.readyState !== undefined ? cur.readyState : -1,
        this.engine.getPageGeneration());
      this.refreshPage();
    }
  }

  /** 进度行左右翻页按钮：仅更新阅读内容，不销毁 / 不重建底部控制栏实例 */
  private turnPageBy(direction: TurnDirection): void {
    if (this.pageDestroyed) {
      return;
    }
    const ok: boolean = this.engine.turnPage(direction);
    if (ok) {
      this.refreshPage();
    } else {
      this.pageRenderer.renderPage();
    }
  }

  /** 应用系统/导入字体（注册/复用为自定义字体主题并切换） */
  private applyFontFamily(family: string): void {
    if (family.length === 0) {
      return;
    }
    const mgr = this.engine.getFontThemeManager();
    const id: string = 'sys-' + family;
    const exists: boolean = mgr.getAllThemes().some((t: FontTheme): boolean => t.id === id);
    if (!exists) {
      const theme: FontTheme = {
        id: id,
        name: family,
        fontFamily: family,
        cjkFontFamily: family,
        monospaceOverride: 'monospace',
        loadingStrategy: 'none'
      };
      mgr.addCustomTheme(theme);
    }
    mgr.switchTheme(id);
    this.currentFontThemeId = id;
    this.refreshPage();
    this.persistSettings();
  }

  /** 拖动进度条浮层信息：真实章节名 + 页码/总页码 */
  private querySeekInfo(v: number): SeekInfo {
    return ReaderInfo.seekInfo(this.engine, v, this.totalPages);
  }

  /** 章节真实标题：优先章节 Link.title，再回退到目录匹配，最后「第 N 章」 */
  private chapterTitleAt(chapterIdx: number): string {
    return ReaderInfo.chapterTitle(this.engine, chapterIdx);
  }

  // ==================== 自动翻页 ====================

  private startAutoTurn(): void {
    hilog.info(0x0000, READER_TAG, 'startAutoTurn enter autoSpeed=%{public}d cur=%{public}d total=%{public}d state=%{public}s pub=%{public}d',
      Math.round(this.autoSpeed * 100), this.engine.getGlobalPageNumber(), this.engine.getTotalPages(),
      this.engine.getState(), this.engine.getPublication() !== undefined ? 1 : 0);
    this.autoTurning = true;
    this.showAutoTurnBar = false;
    this.hideControls();
    this.startAutoTurnTimer();
  }

  private stopAutoTurn(): void {
    hilog.info(0x0000, READER_TAG, 'stopAutoTurn enter autoTurning=%{public}d timer=%{public}d cur=%{public}d total=%{public}d',
      this.autoTurning ? 1 : 0, this.autoTurnTimer, this.engine.getGlobalPageNumber(), this.engine.getTotalPages());
    this.autoTurning = false;
    this.showAutoTurnBar = false;
    if (this.autoTurnTimer > 0) {
      clearInterval(this.autoTurnTimer);
      this.autoTurnTimer = -1;
    }
  }

  private startAutoTurnTimer(): void {
    hilog.info(0x0000, READER_TAG, 'startAutoTurnTimer enter autoTurning=%{public}d autoSpeed=%{public}d timer=%{public}d',
      this.autoTurning ? 1 : 0, Math.round(this.autoSpeed * 100), this.autoTurnTimer);
    if (this.autoTurnTimer > 0) {
      clearInterval(this.autoTurnTimer);
      this.autoTurnTimer = -1;
    }
    if (!this.autoTurning) {
      return;
    }
    const interval: number = Math.max(500, Math.round(3000 / this.autoSpeed));
    hilog.info(0x0000, READER_TAG, 'startAutoTurnTimer schedule interval=%{public}d', interval);
    this.autoTurnTimer = setInterval(() => {
      if (this.pageDestroyed || !this.autoTurning || this.showAutoTurnBar) {
        hilog.info(0x0000, READER_TAG, 'autoTick skip destroyed=%{public}d turning=%{public}d bar=%{public}d',
          this.pageDestroyed ? 1 : 0, this.autoTurning ? 1 : 0, this.showAutoTurnBar ? 1 : 0);
        return;
      }
      hilog.info(0x0000, READER_TAG, 'autoTick before cur=%{public}d total=%{public}d state=%{public}s pub=%{public}d pageSlots=%{public}d',
        this.engine.getGlobalPageNumber(), this.engine.getTotalPages(),
        this.engine.getState(), this.engine.getPublication() !== undefined ? 1 : 0,
        this.engine.getPageByGlobalIndex(0) !== undefined ? 1 : 0);
      const ok: boolean = this.engine.turnPage(TurnDirection.FORWARD);
      hilog.info(0x0000, READER_TAG, 'autoTick turnPage=%{public}d after cur=%{public}d total=%{public}d state=%{public}s',
        ok ? 1 : 0, this.engine.getGlobalPageNumber(), this.engine.getTotalPages(), this.engine.getState());
      if (ok) {
        this.refreshPage();
      } else {
        // 到最后一页自动停止；未到末页的异常失败保留自动翻页并告警（避免误停）
        const cur: number = this.engine.getGlobalPageNumber();
        const total: number = this.engine.getTotalPages();
        if (cur >= total) {
          this.stopAutoTurn();
        } else {
          hilog.warn(0x0000, READER_TAG, 'autoTick turnPage=false but cur=%{public}d<total=%{public}d, keep auto turn', cur, total);
        }
      }
    }, interval);
  }

  private restartAutoTurnTimer(): void {
    if (this.autoTurning && !this.showAutoTurnBar) {
      this.startAutoTurnTimer();
    }
  }

  /** 自动翻页中点击正文：唤起自动翻页控制栏（暂停自动翻页） */
  private onAutoTurnTap(): void {
    hilog.info(0x0000, READER_TAG, 'onAutoTurnTap enter autoTurning=%{public}d bar=%{public}d',
      this.autoTurning ? 1 : 0, this.showAutoTurnBar ? 1 : 0);
    if (!this.autoTurning) {
      return;
    }
    if (this.autoTurnTimer > 0) {
      clearInterval(this.autoTurnTimer);
      this.autoTurnTimer = -1;
    }
    this.showAutoTurnBar = true;
  }

  // ==================== 选择 / 标注 ====================

  private clearSelection(): void {
    this.selection = null;
    this.pageRenderer.renderPage();
  }

  /** 根据选区创建标注（高亮/划线/笔记） */
  private addAnnotationFromSelection(type: AnnotationType, noteText?: string): void {
    if (this.selection === null) {
      return;
    }
    const pub = this.engine.getPublication();
    if (pub === undefined) {
      return;
    }
    const bookId: string = pub.getMetadata().title;
    const now: string = new Date().toISOString();
    const nowMs: number = new Date().getTime();
    const chapterIdx: number = this.engine.getCurrentChapterIndex();
    const loc: Locator = {
      href: '',
      chapterIndex: chapterIdx,
      paragraphIndex: this.selection.startCharOffset,
      wordIndex: this.selection.endCharOffset
    } as Locator;
    const ann: Annotation = {
      id: 'ann_' + now + '_' + Math.floor(Math.random() * 100000),
      type: type,
      locator: loc,
      text: this.selection.text,
      note: noteText !== undefined ? noteText : '',
      color: undefined,
      created: now,
      modified: now,
      chapterIndex: chapterIdx,
      startCharOffset: this.selection.startCharOffset,
      endCharOffset: this.selection.endCharOffset,
      synchronizationVersion: 0,
      noteText: noteText !== undefined ? noteText : undefined,
      noteTimestamp: nowMs,
      createdAt: nowMs,
      updatedAt: nowMs,
      isVisible: 1
    };
    this.engine.getAnnotationStorage().save(bookId, ann);
    this.annotations.push(ann);
    this.engine.syncAnnotations(this.annotations);
    this.selection = null;
    this.pageRenderer.renderPage();
  }

  private isNonSystemLanguage(text: string): boolean {
    return ReaderTextUtils.isNonSystemLanguage(text);
  }

  private hasLetters(text: string): boolean {
    return ReaderTextUtils.hasLetters(text);
  }

  private showPlaceholderToast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (_e) {
    }
  }

  private isSingleWord(text: string): boolean {
    return ReaderTextUtils.isSingleWord(text);
  }

  private computeSelectionText(s: SelectionRange): string {
    return ReaderTextUtils.selectionText(s, this.pageLines);
  }

  // ==================== 目录 / 书签 / 笔记 ====================

  /** 有书签的章节索引集合 */
  private bookmarkChapterSet(): Set<number> {
    return ReaderInfo.bookmarkChapters(this.bookmarks);
  }

  /** 有笔记/标注的章节索引集合 */
  private noteChapterSet(): Set<number> {
    return ReaderInfo.noteChapters(this.annotations);
  }

  /** 目录项 → 章节索引（与 isCurrentTocItem 同源） */
  private tocChapterIndices(): number[] {
    return ReaderInfo.tocChapterIndices(this.engine);
  }

  /** 当前书籍标题（目录卡片封面行展示） */
  private currentBookTitle(): string {
    return ReaderInfo.currentBookTitle(this.engine);
  }

  /** 封面绝对路径：相对路径基于书籍资源基路径解析（无封面返回空串） */
  private resolvedCoverPath(): string {
    return ReaderInfo.resolvedCoverPath(this.engine, this.pageRenderer.getBookBasePath());
  }

  /** 目录项 → 章节起始全局页码（前缀和；无法定位为 -1） */
  private tocPageNumbers(): number[] {
    return ReaderInfo.tocPageNumbers(this.engine);
  }

  /** 判断目录项是否为"包含当前页的章节"（高亮显示） */
  private isCurrentTocItem(item: TocItem): boolean {
    return ReaderInfo.isCurrentTocItem(this.engine, item);
  }

  /** 下拉添加书签成功：以当前章节 + 章节内起始字符偏移作为唯一锚点 */
  private toggleBookmarkAtCurrentPage(): void {
    if (!this.featureFlags.bookmarks) {
      return;
    }
    const pub = this.engine.getPublication();
    if (pub === undefined) {
      return;
    }
    const bookId: string = pub.getMetadata().title;
    const chapterIdx: number = this.engine.getCurrentChapterIndex();
    const page = this.engine.getCurrentPage();
    const charOffset: number = page !== undefined && page.lines.length > 0
      ? page.lines[0].startCharOffset : 0;
    let existingId: string = '';
    for (let i = 0; i < this.bookmarks.length; i++) {
      const bm: Bookmark = this.bookmarks[i];
      if (bm.chapterIndex === chapterIdx && bm.charOffset === charOffset) {
        existingId = bm.id;
        break;
      }
    }
    if (existingId.length > 0) {
      this.bookmarkStorage.remove(bookId, existingId);
      const kept: Bookmark[] = [];
      for (let i = 0; i < this.bookmarks.length; i++) {
        if (this.bookmarks[i].id !== existingId) {
          kept.push(this.bookmarks[i]);
        }
      }
      this.bookmarks = kept;
      hilog.info(0x0000, READER_TAG, 'bookmark toggled OFF ch=%{public}d, left=%{public}d', chapterIdx, kept.length);
      this.showPlaceholderToast('已移除书签');
    } else {
      const now: number = Date.now();
      const chapterLink = pub.getChapterLink(chapterIdx);
      const preview: string = page !== undefined && page.lines.length > 0 ? page.lines[0].text : '';
      const bm: Bookmark = {
        id: 'bm_' + now + '_' + chapterIdx,
        chapterIndex: chapterIdx,
        charOffset: charOffset,
        chapterHref: chapterLink !== undefined ? chapterLink.href : undefined,
        textPreview: preview.length > 40 ? preview.substring(0, 40) : preview,
        createdAt: now,
        type: 'bookmark'
      };
      this.bookmarkStorage.save(bookId, bm);
      this.bookmarks.push(bm);
      hilog.info(0x0000, READER_TAG, 'bookmark toggled ON ch=%{public}d total=%{public}d offset=%{public}d',
        chapterIdx, this.bookmarks.length, charOffset);
      this.showPlaceholderToast('已添加书签');
    }
    this.pageRenderer.renderPage();
  }

  /** 下拉位移变化（含拖动 / 弹簧回弹）：逐帧驱动画布重绘书签填充动画 */
  private onPullDistanceChanged(): void {
    if (this.pageDestroyed) {
      return;
    }
    this.pageRenderer.renderPage();
  }

  private refreshPage(): void {
    const page = this.engine.getCurrentPage();
    if (page !== undefined) {
      this.pageLines = page.lines;
    }
    // Phase 24/25：文档空间页码（与 getTotalPages 同空间）
    this.currentPageNum = this.engine.getDocumentPageNumber();
    this.totalPages = this.engine.getTotalPages();
    this.updateChapterPageInfo();
    this.selection = null; // 换页清除选词
    if (page !== undefined) {
      this.pageRenderer.prefetchRemoteImages(page.lines);
      const lines: LineBox[] = page.lines;
      for (let i = 0; i < lines.length; i++) {
        const src: string | undefined = lines[i].imageSrc;
        if (src !== undefined && src.length > 0 && !(src.startsWith('http://') || src.startsWith('https://'))) {
          this.pageRenderer.preloadLocalImage(src);
        }
        const markerSrc: string | undefined = lines[i].markerImageSrc;
        if (markerSrc !== undefined && markerSrc.length > 0 && !(markerSrc.startsWith('http://') || markerSrc.startsWith('https://'))) {
          this.pageRenderer.preloadLocalImage(markerSrc);
        }
      }
    }
    this.pageRenderer.prefetchNextPageImages();
    // Phase 10 S3：N-1 图片与 N+1 对称预取（冷启动立即翻上一页不再空白图片区）
    this.pageRenderer.prefetchPreviousPageImages();
    this.pageRenderer.renderPage();
    // 液态玻璃：页面内容变化 → 重取背景（回读很贵，仅控制层可见时执行）
    if (this.showControls) {
      OhGlass.recapture();
    }
  }

  /** 顶栏/底栏显隐：组件刚创建时矩形尚未解算，稍等一帧后重算并重截背景 */
  private onControlsVisibleChanged(): void {
    if (!this.showControls) {
      return;
    }
    setTimeout((): void => {
      if (!this.pageDestroyed) {
        OhGlass.recapture();
      }
    }, 30);
  }

  /**
   * Phase 10 观测：翻页后 N-1/N/N+1 就绪快照（所有翻页模式共用出口）。
   * 输出引擎侧就绪状态 + 渲染侧图片解码进度，用于证明冷启动 N-1 与 N+1 的不对称。
   */
  private logPageTurnSnapshot(tag: string): void {
    hilog.info(0x0000, READER_TAG, 'P10 %{public}s mode=%{public}s %{public}s',
      tag, String(this.turnMode), this.engine.describeNeighborWindow());
  }

  // ── Export ──
  private exportAnnotations(format: string): void {
    const pub = this.engine.getPublication();
    let bookTitle: string = 'Unknown';
    let chapterTitles: string[] = [];
    if (pub !== undefined) {
      bookTitle = pub.getMetadata().title;
      const toc = pub.getToc();
      if (toc !== undefined) {
        for (let i: number = 0; i < toc.length; i++) {
          chapterTitles.push(toc[i].title);
        }
      }
    }
    let content: string = '';
    let ext: string = '';
    if (format === 'json') {
      content = AnnotationExporter.toJson(this.annotations);
      ext = 'json';
    } else if (format === 'markdown') {
      content = AnnotationExporter.toMarkdown(this.annotations, chapterTitles);
      ext = 'md';
    } else if (format === 'html') {
      content = AnnotationExporter.toHtml(this.annotations, bookTitle, chapterTitles);
      ext = 'html';
    } else if (format === 'csv') {
      content = AnnotationExporter.toCsv(this.annotations);
      ext = 'csv';
    } else {
      return;
    }
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      return;
    }
    const ctx: Context = hostCtx;
    try {
      const path: string = ctx.filesDir + '/annotations.' + ext;
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
      fileIo.closeSync(file);
    } catch (e) {
    }
  }

  private saveThemePreference(themeId: string): void {
    ReaderThemeUtils.savePreference(this.getUIContext().getHostContext(), themeId);
  }

  private hideControls(): void {
    this.showControls = false;
    this.showSettings = false;
    this.cancelControlsAutoHide();
    if (!this.topStatusBarResident) {
      this.setStatusBarVisible(false);
    }
  }

  /** 进入沉浸式：窗口全屏布局 + 隐藏状态栏/导航条，并重读避让区 */
  private async enableImmersive(win: window.Window): Promise<void> {
    try {
      await win.setWindowLayoutFullScreen(true);
      await win.setWindowSystemBarEnable([]);
      try {
        await win.setSpecificSystemBarEnabled('status', false);
        await win.setSpecificSystemBarEnabled('navigationIndicator', false);
      } catch (_e2) {
      }
      try {
        await win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          statusBarContentColor: '#00000000',
          navigationBarColor: '#00000000',
          navigationBarContentColor: '#00000000'
        });
      } catch (_e3) {
      }
      this.statusBarVisible = false;
      const sysAvoid: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navAvoid: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.avoidAreaBottom =
        Math.round((sysAvoid.bottomRect.height + navAvoid.bottomRect.height) / this.screenDensity);
      this.avoidAreaTopVp = Math.round(sysAvoid.topRect.height / this.screenDensity);
    } catch (_e) {
    }
  }

  /** 预留接口：单独控制顶部状态栏显隐（true=显示，false=隐藏） */
  private async setStatusBarVisible(visible: boolean): Promise<void> {
    if (this.mainWindow === null) {
      return;
    }
    try {
      await this.mainWindow.setWindowSystemBarEnable(visible ? ['status'] : []);
      this.statusBarVisible = visible;
    } catch (_e) {
    }
  }

  /** 退出阅读器：恢复系统栏显示 + 退出全屏布局 */
  private async restoreSystemBar(): Promise<void> {
    if (this.mainWindow === null) {
      return;
    }
    try {
      await this.mainWindow.setWindowSystemBarEnable(['status', 'navigation']);
      await this.mainWindow.setWindowLayoutFullScreen(false);
    } catch (_e) {
    }
  }

  /** 控制层唤出后启动 10s 无操作自动隐藏 */
  private scheduleControlsAutoHide(): void {
    this.cancelControlsAutoHide();
    this.controlsTimer = setTimeout(() => {
      this.controlsTimer = -1;
      if (this.pageDestroyed) {
        return;
      }
      // 面板（半模态）打开时视为仍在操作：顺延而非隐藏
      if (this.showSettings || this.quickPanelOpen) {
        this.scheduleControlsAutoHide();
        return;
      }
      this.hideControls();
    }, ReaderHost.CONTROLS_AUTO_HIDE_MS);
  }

  private cancelControlsAutoHide(): void {
    if (this.controlsTimer > 0) {
      clearTimeout(this.controlsTimer);
      this.controlsTimer = -1;
    }
  }

  /** 控制层内的任意操作：重置 10s 自动隐藏计时 */
  private onControlsInteraction(): void {
    if (this.showControls) {
      this.scheduleControlsAutoHide();
    }
  }

  private getReaderViewport(): ReaderViewport {
    return {
      canvasW: this.canvasW,
      canvasH: this.canvasH,
      contentWidth: this.contentWidth,
      contentHeight: this.contentHeight,
      margins: this.margins,
      avoidAreaTopVp: this.avoidAreaTopVp
    };
  }

  // ==================== 选区菜单锚点 ====================

  private updateSelectionMenu(): void {
    if (this.selection === null) {
      return;
    }
    const s: SelectionRange = this.selection;
    // 计算菜单锚点：选区的第一行上方（内容坐标 → 全屏 vp）
    const lines: LineBox[] = this.pageLines;
    if (s.startLineIndex >= 0 && s.startLineIndex < lines.length) {
      const startLine: LineBox = lines[s.startLineIndex];
      const startLocal: number = Math.max(0, s.startCharOffset - startLine.startCharOffset);
      // Phase 16.3: 选择菜单定位前按行恢复逐字几何（防止空数组→菜单错位）
      this.engine.ensureLineGeometry(startLine);
      let ax: number = this.margins.left + (startLine.charPositions.length > 0
        ? startLine.charPositions[Math.min(startLocal, startLine.charPositions.length - 1)]
        : 0);
      let ay: number = this.margins.top + this.avoidAreaTopVp + startLine.renderedY - 44;
      if (ax + 210 > this.canvasW) {
        ax = this.canvasW - 214;
      }
      if (ay < this.avoidAreaTopVp + 8) {
        ay = this.avoidAreaTopVp + 8;
      }
      this.selectionMenuX = ax;
      this.selectionMenuY = ay;
    }
    this.showTranslate = this.featureFlags.translation && this.isNonSystemLanguage(s.text);
    this.showDictionary = this.isSingleWord(s.text);
  }
}