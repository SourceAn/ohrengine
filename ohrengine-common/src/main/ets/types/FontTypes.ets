/**
 * FontTypes — Shared font-related type definitions
 *
 * Contains types extracted from FontFaceParser.ets and
 * RemoteResourceLoader.ets that are needed by FontLoader
 * (in ohrengine-common/font/).
 */

/**
 * A single font source descriptor from a src property.
 */
export interface FontSource {
  url: string;
  format?: string;
}

/**
 * A parsed @font-face rule.
 */
export interface FontFaceRule {
  familyName: string;
  src: FontSource[];
  fontWeight?: string;
  fontStyle?: string;
  unicodeRange?: string;
}

/**
 * Result container for @font-face parsing.
 */
export interface FontFaceParseResult {
  rules: FontFaceRule[];
  cssBasePath: string;
}

/**
 * Load result from a resource fetch operation.
 */
export interface LoadResult {
  success: boolean;
  data: Object | null;
  mimeType: string;
  fromCache: boolean;
}

/**
 * Minimal resource fetcher interface for FontLoader.
 *
 * FontLoader needs to download remote font files. Rather than
 * depending on the full RemoteResourceLoader (in ohrengine-ui-render),
 * this interface defines the minimal contract. The actual
 * RemoteResourceLoader (or any other fetcher) implements this.
 */
export interface ResourceFetcher {
  fetchBinary(url: string): Promise<LoadResult>;
}

/**
 * 字体注册回调（ENG-002）
 *
 * font.registerFont() 已废弃；应使用 UIContext.getFont().registerFont()。
 * UIContext 只能在 UI 线程的组件内获取，而 FontLoader 运行在引擎层，
 * 因此由 UI 层把实际注册逻辑注入进来：
 *
 *   uiContext.getFont().registerFont({ familyName, familySrc })
 *
 * 注入方需保证回调运行在 UI 线程，并持有有效的 UIContext 生命周期。
 */
export interface FontRegistrar {
  registerFont: (familyName: string, familySrc: string) => void;
}
