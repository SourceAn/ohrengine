import { Theme, PRESET_THEMES } from 'ohrengine-common';

export class ThemeManager {
  private current: Theme = PRESET_THEMES[0];
  private listeners: Array<(t: Theme) => void> = [];

  get currentTheme(): Theme {
    return this.current;
  }

  switchTheme(id: string): void {
    const t: Theme | undefined = PRESET_THEMES.find(x => x.id === id);
    if (t === undefined || t.id === this.current.id) {
      return;
    }
    this.current = t;
    for (const cb of this.listeners) {
      cb(t);
    }
  }

  onThemeChange(cb: (t: Theme) => void): void {
    this.listeners.push(cb);
  }
}
