import { UIAbility, AbilityConstant, Want, ConfigurationConstant, Configuration } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ParserRegistry, MemoryPressureHub, ImportService } from 'ohrengine-common';
import { EpubParser } from 'ohrengine-epub';
import BuildProfile from '../BuildProfile';
import { TxtParser } from 'ohrengine-txt-exclusive';
import { CbzParser } from 'ohrengine-cbz-exclusive';
import { PdfParser } from 'ohrengine-pdf-exclusive';
import { FeatureDataCleaner } from '../deletion/FeatureDataCleaner';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'OhEngineEntry', 'ABILITY_CREATE keys=%{public}s wantJson=%{public}s',
      want !== undefined && want.parameters !== undefined
        ? JSON.stringify(Object.keys(want.parameters)) : 'none',
      want !== undefined && want.parameters !== undefined ? JSON.stringify(want.parameters) : 'none');
    // Register format parsers (moved from OhEngineCore to decouple ui-render
    // from format-specific modules). Routers stay registered in OhEngine.
    ParserRegistry.register(new EpubParser());
    ParserRegistry.register(new TxtParser());
    ParserRegistry.register(new CbzParser());
    // PDF：注册桩解析器，parse() 明确抛"不支持"，避免 .pdf 落入解压/半初始化路径
    // （ENG-006）
    ParserRegistry.register(new PdfParser());
    // 注册应用层关联数据清理器（批注/书签），供 ImportService.deleteBook 统一编排清理
    ImportService.registerAssociatedDataCleaner(new FeatureDataCleaner(this.context));
    this.pocWant = want;
    this.syncDarkMode();
  }

  /** 系统深浅色变化：同步到 AppStorage('darkMode')，供阅读器面板/材质跟随 */
  onConfigurationUpdate(newConfig: Configuration): void {
    this.syncDarkMode();
  }

  private syncDarkMode(): void {
    try {
      const dark: boolean =
        this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      AppStorage.setOrCreate('darkMode', dark);
    } catch (e) {
    }
  }

  onDestroy(): void {
  }

  /**
   * Phase 3 (L3): 系统内存告警 → 广播给阅读引擎（MemoryPressureHub），
   * 引擎侧将 L3 内存页缓存 shrink 到 1–2 章（保留可见页），
   * 不阻塞主线程、不依赖任何页面状态。
   */
  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    MemoryPressureHub.publish(level);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const pc: Object | undefined = this.pocWant?.parameters?.['pocCase'];
    const pb: Object | undefined = this.pocWant?.parameters?.['pocBg'];
    if (pc !== undefined) { AppStorage.setOrCreate('pocCase', String(pc)); }
    if (pb !== undefined) { AppStorage.setOrCreate('pocBg', String(pb)); }
    // 调试直达（与 pocCase 同一注入模式）：want 参数 bookPath → 书架页消费后
    // 直接跳阅读器；debugShelf=1 → 直接加载调试/导入书架页。
    const bp: Object | undefined = this.pocWant?.parameters?.['bookPath'];
    if (bp !== undefined) { AppStorage.setOrCreate('autoOpenBookPath', String(bp)); }
    const dbg: Object | undefined = this.pocWant?.parameters?.['debugShelf'];
    if (dbg !== undefined) { AppStorage.setOrCreate('debugShelfMode', String(dbg)); }
    // 沉浸式：全屏布局（内容延伸到状态栏/导航栏区域）+ 系统栏透明
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true);
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: '#000000',
        navigationBarContentColor: '#000000'
      } as window.SystemBarProperties);
    } catch (e) {
    }
    windowStage.loadContent(this.getEntryPage(), (err) => {
      if (err.code) {
      }
    });
  }

  /**
   * Debug/Release 入口分离（ENG-012）+ Phase 25 调试直达：
   *   - want 参数 debugShelf=1 → 调试/导入书架（hdc shell aa start --ps debugShelf 1）
   *   - 否则 Debug 构建 → 调试书架；Release 构建 → 正式书架。
   *
   * 通过 hvigorfile.ts 在构建期注入的编译期常量 BuildProfile.DEBUG 区分——
   * 构建期静态确定（debug 构建 DEBUG=true，release 构建 DEBUG=false），
   * 不是运行时字符串判断，Release 产物不携带调试分支。
   */
  private getEntryPage(): string {
    const dbg: string | undefined = AppStorage.get<string>('debugShelfMode');
    if (dbg !== undefined && dbg === '1') {
      AppStorage.setOrCreate('debugShelfMode', '');
      return 'debug/DebugBookshelf';
    }
    if (BuildProfile.DEBUG) {
      return 'debug/DebugBookshelf';
    }
    return 'pages/Bookshelf';
  }

  private pocWant?: Want;
}
