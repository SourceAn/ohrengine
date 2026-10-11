/**
 * 字号统一控制器
 * 
 * 引擎中唯一的字号管理入口。
 * 所有"字号相关"的操作都通过这个类：
 *   - 用户滑块
 *   - CSS 相对单位解析
 *   - 断行测量
 *   - 渲染
 * 
 * 重构说明（模块化改造）：
 *   原构造参数 OhEngineCore 替换为 onFontSizeChanged 回调，
 *   解除 common → ui-render 的循环依赖。
 *   UI 层在构建 FontSizeController 时传入 () => void 回调。
 */
import { CssLength, CssValueType } from '../document/CssDefinitions.ets';

export class FontSizeController {
  /** ★★★ 唯一用户可调字段 ★★★ fp，默认 16 */
  private _userFontSize: number = 16;

  /** 字号变更回调（触发引擎重排） */
  private onFontSizeChanged: () => void;

  /** CSS 标签字号比例缓存：tagName → 比例（如 h1 → 2.0） */
  private cssTagRatios: Map<string, number> = new Map();

  constructor(onFontSizeChanged: () => void) {
    this.onFontSizeChanged = onFontSizeChanged;
  }

  /** ===== 唯一的外部设置入口 ===== */

  /** 用户调字号（滑块）— 仅更新值，不触发重排 */
  setUserFontSize(newSize: number): void {
    this._userFontSize = newSize;
  }

  /** 提交字号变更（触发引擎全量重排） */
  applyUserFontSize(): void {
    this.onFontSizeChanged();
  }

  /** 获取当前用户字号 */
  get userFontSize(): number {
    return this._userFontSize;
  }

  /** ===== 为各子系统提供的只读派生值 ===== */

  /** TextBreaker 断行用的字号 = userFontSize */
  get baseFontSize(): number {
    return this._userFontSize;
  }

  /** CSS 相对单位的参考值：1em = userFontSize */
  get cssReferenceSize(): number {
    return this._userFontSize;
  }

  /**
   * 获取某个 DOM 节点的实际渲染字号
   * @param tagName 标签名
   * @returns 渲染字号（fp）
   */
  getRenderFontSize(tagName: string): number {
    const ratio = this.cssTagRatios.get(tagName.toLowerCase());
    if (ratio !== undefined) {
      return this._userFontSize * ratio;
    }
    return this._userFontSize;
  }

  /** ===== CSS 字号规则注册 ===== */

  /** 注册标签默认字号比例（从 CSS 编译时调用） */
  registerCssTagFontSize(tagName: string, cssFontSize: CssLength): void {
    const ratio = this.cssValueToRatio(cssFontSize);
    this.cssTagRatios.set(tagName.toLowerCase(), ratio);
  }

  /** 解析 CSS font-size 值的实际像素 */
  resolveCssFontSize(cssValue: CssLength): number {
    switch (cssValue.type) {
      case CssValueType.SCREEN_PX:
        return cssValue.value;
      case CssValueType.PX:
        return cssValue.value / 256;
      case CssValueType.PT:
        return cssValue.value / 256 * 1.333;
      case CssValueType.EM:
      case CssValueType.PERCENT:
        return cssValue.value / 256 * this._userFontSize;
      default:
        return this._userFontSize;
    }
  }

  private cssValueToRatio(cssValue: CssLength): number {
    if (cssValue.type === CssValueType.EM || cssValue.type === CssValueType.PERCENT) {
      return cssValue.value / 256;
    }
    const px = this.resolveCssFontSize(cssValue);
    return px / this._userFontSize;
  }
}
