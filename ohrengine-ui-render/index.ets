/**
 * ohrengine-ui-render — Public API exports
 *
 * Re-exports all public types and classes from the UI render module.
 */

// Top-level engine classes
export { OhEngineCore } from './src/main/ets/OhEngineCore.ets';
export { OhEngine } from './src/main/ets/OhEngine.ets';

// Core managers
export { PageManager, PageManagerHost } from './src/main/ets/core/PageManager.ets';
export { PipelineManager, PipelineManagerHost } from './src/main/ets/core/PipelineManager.ets';
export { LayoutPriority } from './src/main/ets/core/PipelineManager.ets';

// Routers
export { ReflowRouter } from './src/main/ets/router/ReflowRouter.ets';
export { ImageRouter } from './src/main/ets/router/ImageRouter.ets';

// Renderers
export { ImageRenderer, ImagePageResult } from './src/main/ets/render/ImageRenderer.ets';

// Layout — all layout components
export { PageSplitter, PaginatedChapter, Page, PaginationConfig, createDefaultPaginationConfig, createPaginatedChapter, createEmptyPage } from './src/main/ets/layout/PageSplitter.ets';
export { StyleMapper } from './src/main/ets/style/StyleMapper.ets';
export { CompiledStylesheet, compileRuleSet } from './src/main/ets/style/CssCompiler.ets';
export type { CompiledRule } from './src/main/ets/style/CssCompiler.ets';
export { FontLoader } from './src/main/ets/typography/FontLoader.ets';
export { FontFallbackChain } from 'ohrengine-common';
export type { TextSegment, LoadedFontInfo } from 'ohrengine-common';
export { FontFallbackCache } from 'ohrengine-common';
export { LayoutEngine } from './src/main/ets/layout/LayoutEngine.ets';
export { FlexLayoutEngine } from './src/main/ets/layout/FlexLayoutEngine.ets';
export { FloatLayoutEngine } from './src/main/ets/layout/FloatLayoutEngine.ets';
export { justify } from './src/main/ets/typography/JustifyEngine.ets';
export { TextBreaker } from './src/main/ets/typography/TextBreaker.ets';
export type { BreakerResult } from './src/main/ets/typography/TextBreaker.ets';
export { ReadingMetrics } from './src/main/ets/typography/ReadingMetrics.ets';
export { MediaQueryEvaluator, MediaContext, MediaConditionalCompiler } from './src/main/ets/style/MediaQueryEvaluator.ets';
export { SelectorMatcher } from './src/main/ets/style/SelectorMatcher.ets';
export { CssImportResolver } from './src/main/ets/style/CssImportResolver.ets';
export { CssCounterManager } from './src/main/ets/style/CssCounterManager.ets';
export { RemoteResourceLoader, RequestCanceller } from './src/main/ets/layout/RemoteResourceLoader.ets';
export { AnnotationRenderer } from './src/main/ets/layout/AnnotationRenderer.ets';
export { TableRenderer } from './src/main/ets/layout/TableRenderer.ets';
export type { TablePageBreakInfo } from './src/main/ets/layout/TableRenderer.ets';
export type { GridResult, TableElement, TableRow, TableCell,
              RubyPair, GridCell } from 'ohrengine-common';
export { ListLayoutEngine, ListStyleType, generateMarker, getLevelDefaultMarkerType, estimateMarkerWidth } from './src/main/ets/layout/ListRenderer.ets';
export type { ListItemLayout } from './src/main/ets/layout/ListRenderer.ets';
export { SvgRenderer } from './src/main/ets/layout/SvgRenderer.ets';
export { MathMLRenderer } from './src/main/ets/layout/MathMLRenderer.ets';
export type { MathMlRenderOptions } from './src/main/ets/layout/MathMLRenderer.ets';
export { RubyRenderer } from './src/main/ets/layout/RubyRenderer.ets';
export type { LineRubySegment, RubyRenderOptions } from './src/main/ets/layout/RubyRenderer.ets';
export { FauxBoldItalicRenderer } from './src/main/ets/layout/FauxBoldItalicRenderer.ets';
