import { window } from '@kit.ArkUI';
import { ThemePreferenceStorage } from 'ohrengine-feature';

/**
 * ReaderThemeUtils — 主题相关纯工具（从 Index 拆分）。
 * 含：深浅色目标计算、系统状态栏/导航栏颜色同步、主题偏好持久化。
 */
export class ReaderThemeUtils {
  /** 深浅色切换目标 id（day ↔ night） */
  static nextId(curId: string): string {
    return curId === 'night' ? 'day' : 'night';
  }

  /** 主题对应的系统栏内容色 */
  static contentColorOf(themeId: string): string {
    return themeId === 'night' ? '#FFFFFF' : '#000000';
  }

  /** 同步系统状态栏 / 导航栏内容颜色（失败静默） */
  static syncSystemBarColor(themeId: string, hostCtx: Context | undefined): void {
    if (hostCtx === undefined) {
      return;
    }
    const contentColor: string = ReaderThemeUtils.contentColorOf(themeId);
    window.getLastWindow(hostCtx).then((mainWindow: window.Window) => {
      mainWindow.setWindowSystemBarProperties({
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      } as window.SystemBarProperties);
    }).catch((e: Error) => {
    });
  }

  /** 持久化主题偏好（失败静默） */
  static savePreference(ctx: Context | undefined, themeId: string): void {
    if (ctx !== undefined) {
      new ThemePreferenceStorage().save(ctx, themeId);
    }
  }
}