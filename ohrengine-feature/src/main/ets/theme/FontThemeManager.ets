/**
 * FontThemeManager — Font theme management system
 *
 * Provides:
 *   1. FontTheme interface: defines font-family, size, line spacing, loading strategy
 *   2. FONT_THEMES: 4 built-in presets (serif, sans-serif, monospace, handwriting)
 *   3. FontThemeManager class: switchTheme, onThemeChange, addCustomTheme
 *
 * ARCH-003: FontTheme 接口与 FONT_THEMES 预设已下沉到 ohrengine-common
 * （types/ThemeTypes.ets），本类仅承载状态与事件逻辑。
 *
 * Usage:
 *   const mgr = new FontThemeManager('serif');
 *   mgr.onThemeChange((t) => { applyTheme(t); });
 *   mgr.switchTheme('monospace');
 */

import { FontTheme, FONT_THEMES } from 'ohrengine-common';

export class FontThemeManager {
  private _currentTheme: FontTheme;
  private _customThemes: FontTheme[] = [];
  private _onChange: ((theme: FontTheme) => void) | null = null;
  /** Tracks font load progress for loadable themes: themeId → loaded (true/false) */
  private _fontLoadStatus: Map<string, boolean> = new Map();

  constructor(defaultThemeId: string = 'sans-serif') {
    const found: FontTheme | null = FontThemeManager.findThemeById(defaultThemeId, this._customThemes);
    this._currentTheme = found ?? FONT_THEMES[1]; // fallback to sans-serif
  }

  public get currentTheme(): FontTheme {
    return this._currentTheme;
  }

  /**
   * Returns all available themes (built-in + custom).
   */
  public getAllThemes(): FontTheme[] {
    const result: FontTheme[] = [];
    for (let i = 0; i < FONT_THEMES.length; i++) {
      result.push(FONT_THEMES[i]);
    }
    for (let i = 0; i < this._customThemes.length; i++) {
      result.push(this._customThemes[i]);
    }
    return result;
  }

  /**
   * Switch to a theme by id (built-in or custom).
   * Fires the onChange callback if registered.
   */
  public switchTheme(id: string): void {
    const theme: FontTheme | null = FontThemeManager.findThemeById(id, this._customThemes);
    if (theme === null) return;
    this._currentTheme = theme;
    if (this._onChange !== null) {
      this._onChange(theme);
    }
  }

  /**
   * Register a callback that fires when the theme changes.
   */
  public onThemeChange(callback: (theme: FontTheme) => void): void {
    this._onChange = callback;
  }

  /**
   * Add a custom (user-defined) font theme.
   * The id must be unique among custom themes.
   */
  public addCustomTheme(theme: FontTheme): void {
    this._customThemes.push(theme);
  }

  /**
   * Mark a loadable font theme as loaded/unloaded.
   */
  public setFontLoadStatus(themeId: string, loaded: boolean): void {
    this._fontLoadStatus.set(themeId, loaded);
  }

  /**
   * Check if a loadable font theme has been loaded.
   */
  public isFontLoaded(themeId: string): boolean {
    return this._fontLoadStatus.get(themeId) ?? false;
  }

  private static findThemeById(id: string, customThemes: FontTheme[]): FontTheme | null {
    for (let i = 0; i < FONT_THEMES.length; i++) {
      if (FONT_THEMES[i].id === id) return FONT_THEMES[i];
    }
    for (let i = 0; i < customThemes.length; i++) {
      if (customThemes[i].id === id) return customThemes[i];
    }
    return null;
  }
}
