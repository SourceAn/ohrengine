import { preferences } from '@kit.ArkData';

export class ThemePreferenceStorage {
  private static readonly KEY = 'reading_theme';
  private static readonly TAG: string = 'OhEngine';

  async save(ctx: Context, themeId: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(ctx, 'theme_prefs');
      await store.put(ThemePreferenceStorage.KEY, themeId);
      await store.flush();
    } catch (e) {}
  }

  async load(ctx: Context): Promise<string> {
    try {
      const store = await preferences.getPreferences(ctx, 'theme_prefs');
      const val: preferences.ValueType = await store.get(ThemePreferenceStorage.KEY, 'day');
      return val as string;
    } catch (e) {
      return 'day';
    }
  }
}
