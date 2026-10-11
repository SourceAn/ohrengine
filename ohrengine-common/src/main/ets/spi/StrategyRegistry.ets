/**
 * StrategyRegistry — Rendering strategy router registry
 *
 * Central registry for StrategyRouter implementations.
 * Each rendering strategy (reflow, image, fixed) has a router
 * that knows how to render a ParsedBook. OhEngineCore uses
 * StrategyRegistry to dispatch rendering to the correct router.
 *
 * Design:
 *   - ARCH-004：支持实例化（`new StrategyRegistry()`）以隔离测试/多引擎；
 *     静态 API（register/resolve/getAll）作为过渡期兼容入口保留。
 *   - Keyed by RenderStrategy name (string)
 *   - Populated at app startup alongside ParserRegistry
 */

import { ParsedBook } from './ParserRegistry.ets';

/**
 * StrategyRouter interface — implemented by all rendering routers.
 *
 * Each router handles one rendering strategy:
 *   - ReflowRouter:    strategy='reflow' — traditional reflowable EPUB/TXT layout
 *   - ImageRouter:     strategy='image'  — page-by-page raster image (CBZ/CBR)
 *   - PdfRouter:       strategy='fixed'  — fixed-layout PDF rendering (future)
 *
 * Usage:
 *   const router = StrategyRegistry.resolve('reflow');
 *   router.render(parsedBook);
 */
export interface StrategyRouter {
  /** The rendering strategy identifier (e.g., 'reflow', 'image', 'fixed') */
  readonly strategy: string;
  /**
   * Render a parsed book using this strategy.
   *
   * @param book - The ParsedBook to render
   */
  render(book: ParsedBook): void;
}

/**
 * StrategyRegistry — singleton registry for StrategyRouter implementations.
 *
 * Usage (at app startup):
 *   import { ReflowRouter } from 'ohrengine-ui-render';
 *   StrategyRegistry.register(new ReflowRouter());
 *
 *   const router = StrategyRegistry.resolve('reflow');
 *   router.render(parsedBook);
 */
export class StrategyRegistry {
  private static routers: Map<string, StrategyRouter> = new Map();

  // ==================== 实例化 API（ARCH-004） ====================

  private readonly instanceRouters: Map<string, StrategyRouter> = new Map();

  constructor() {
  }

  register(router: StrategyRouter): void {
    this.instanceRouters.set(router.strategy, router);
  }

  resolve(strategy: string): StrategyRouter | undefined {
    return this.instanceRouters.get(strategy);
  }

  getAll(): Map<string, StrategyRouter> {
    return new Map(this.instanceRouters);
  }

  clear(): void {
    this.instanceRouters.clear();
  }

  // ==================== 静态兼容 API（过渡期保留） ====================

  /**
   * Register a StrategyRouter implementation.
   *
   * @param router - Router instance to register
   */
  static register(router: StrategyRouter): void {
    StrategyRegistry.routers.set(router.strategy, router);
  }

  /**
   * Resolve a router by strategy name.
   *
   * @param strategy - Strategy name (e.g., 'reflow', 'image', 'fixed')
   * @returns The registered router, or undefined if not registered
   */
  static resolve(strategy: string): StrategyRouter | undefined {
    return StrategyRegistry.routers.get(strategy);
  }

  /**
   * Get all registered routers.
   */
  static getAll(): Map<string, StrategyRouter> {
    return new Map(StrategyRegistry.routers);
  }
}
