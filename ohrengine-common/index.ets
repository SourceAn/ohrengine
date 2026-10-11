/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * ohrengine-common — Public API
 *
 * This file is the public API surface of the ohrengine-common HAR module.
 * All shared types, model classes, services, font utilities, and parser
 * registries are exported from this single entry point.
 *
 * External consumers MUST import ONLY from this file:
 *   import { ParameterBus, Publication, BookParser } from 'ohrengine-common';
 */

// ==================== Core Engine Types ====================

export { EngineState, TurnDirection, ParamCategory,
         createDefaultEngineConfig, CurlModel, PageReadyState }
  from './src/main/ets/types/EngineTypes.ets';
export type { PageSlot, ReadingProgress, PageCacheData, Margins,
              ThemeConfig, EngineConfig, LayoutProfile, AnnotationStats,
              PageGenerationProvider }
  from './src/main/ets/types/EngineTypes.ets';
export { ChapterAnnotationGroup }
  from './src/main/ets/types/EngineTypes.ets';

// ==================== Shared HTML / DOM Types ====================

export { DomNodeType, createBoxModel, createTextNode, createElementNode,
         createDocumentNode, createEmptyLineBox }
  from './src/main/ets/types/HtmlTypes.ets';
export type { BoxModel, DomNode, RenderNode, LineBox, MathMlExpression,
              SvgPoint, SvgViewBox, SvgShape, SvgDocument,
              RubyPair, TableElement, TableRow, TableCell,
              GridResult, GridCell }
  from './src/main/ets/types/HtmlTypes.ets';

// ==================== Font Types ====================

export { FontRegistrar } from './src/main/ets/types/FontTypes.ets';
export { ReaderFeatureFlags } from './src/main/ets/types/FeatureTypes.ets';
export type { FontSource, FontFaceRule, FontFaceParseResult, LoadResult,
              ResourceFetcher }
  from './src/main/ets/types/FontTypes.ets';

// ==================== Theme Types (ARCH-003) ====================
// 纯数据类型/预设常量下沉到 common，解除 ui-render → feature 的类型耦合。
// feature 的 ThemeManager/FontThemeManager 与 ui-render 均引用此处。

export { PRESET_THEMES, FONT_THEMES } from './src/main/ets/types/ThemeTypes.ets';
export type { Theme, FontTheme, IFontThemeProvider }
  from './src/main/ets/types/ThemeTypes.ets';

// ==================== Reading History Types (ARCH-003) ====================

export type { ReadingRecord, RecordPosition, MetaUpdate, IReadingHistoryStore }
  from './src/main/ets/types/ReadingHistoryTypes.ets';

// ==================== Reading State Types (Phase 1: L1) ====================

export { READING_STATE_SCHEMA_VERSION, PARAGRAPH_HASH_ALGORITHM,
         hashParagraphText, extractParagraphs, computeParagraphStarts,
         clampParagraphCharOffset }
  from './src/main/ets/types/ReadingStateTypes.ets';
export type { ReadingAnchor, ReadingState }
  from './src/main/ets/types/ReadingStateTypes.ets';
export { ReadingStateStore }
  from './src/main/ets/runtime/ReadingStateStore.ets';
export { MemoryPageCache }
  from './src/main/ets/cache/MemoryPageCache.ets';
export { MemoryPressureHub }
  from './src/main/ets/runtime/MemoryPressureHub.ets';
export { DiskCacheQuotaManager }
  from './src/main/ets/cache/DiskCacheQuotaManager.ets';
export { CancellationToken }
  from './src/main/ets/runtime/CancellationToken.ets';
export { ImportCheckpoint, ImportStage }
  from './src/main/ets/cache/ImportCheckpoint.ets';
export { BookStorage }
  from './src/main/ets/storage/BookStorage.ets';
export { CacheMigration }
  from './src/main/ets/cache/CacheMigration.ets';
export { VCHAPTER_TARGET_CHARS, VCHAPTER_MAX_OVER, VCHAPTER_PREFIX,
         vchapterId, oldChapterIndexFromId, buildVChapters }
  from './src/main/ets/types/VChapterTypes.ets';
export type { VChapterDef, VChapterMapping }
  from './src/main/ets/types/VChapterTypes.ets';

// ==================== Model Classes ====================

export { Publication, createLocator, createEmptyLocator, AnnotationType, StyleConfig, createDefaultStyleConfig } from './src/main/ets/document/Publication.ets';
export type { Annotation, TocItem, Locator }
  from './src/main/ets/document/Publication.ets';
export type { BookMetadata, ChapterRef, Book, BookSource }
  from './src/main/ets/document/Book.ets';
export { createBookFingerprint } from './src/main/ets/document/Book.ets';
export { Manifest } from './src/main/ets/document/Manifest.ets';
export { Metadata, createContributor } from './src/main/ets/document/Metadata.ets';
export type { Contributor, OpfMeta } from './src/main/ets/document/Metadata.ets';
export { Link, createLink, createLinkWithTitle, createLinkFromJson }
  from './src/main/ets/document/Link.ets';
export { CssStyleSet, createDefaultCssStyleSet, CssFloat,
         CssDisplay, CssWhiteSpace, CssTextAlign, CssFontStyle,
         CssFontWeight, CssFontFamily, CssPageBreak, CssClear,
         CssTextDecoration, CssTextTransform, CssHyphenate, CssBorderStyle,
         CssBorderCollapse, CssDirection, CssVisibility, CssValueType,
         CssBackgroundRepeat, CssBackgroundPosition, createCssLength,
         CssGenericValue, CssLineBreak, CssWordBreak, CssVerticalAlign }
  from './src/main/ets/document/CssDefinitions.ets';
export type { CssLength }
  from './src/main/ets/document/CssDefinitions.ets';

// ==================== Services ====================

export { ParameterBus } from './src/main/ets/runtime/ParameterBus.ets';
export { ParseCacheManager } from './src/main/ets/cache/ParseCacheManager.ets';
export type { ParseMeta, ParseChapterIndex, ParseChapterChunk }
  from './src/main/ets/cache/ParseCacheManager.ets';
export { PARSE_CHUNK_DIR } from './src/main/ets/cache/ParseCacheManager.ets';
export { PageCacheManager, PAGE_CACHE_SCHEMA_VERSION, LAYOUT_ALGORITHM_VERSION } from './src/main/ets/cache/PageCacheManager.ets';
export type { PageCacheContext, CacheChapter, CachePage, DeserializeDiag, PageCountIndex }
  from './src/main/ets/cache/PageCacheManager.ets';
export { SecureArchive } from './src/main/ets/storage/SecureArchive.ets';
export type { SecureExtractLimits }
  from './src/main/ets/storage/SecureArchive.ets';
export { FontSizeController }
  from './src/main/ets/typography/FontSizeController.ets';

// ==================== Font ====================

export { FontLoader } from './src/main/ets/typography/FontLoader.ets';
export type { LoadedFontInfo }
  from './src/main/ets/typography/FontFallbackChain.ets';
export { FontFallbackChain } from './src/main/ets/typography/FontFallbackChain.ets';
export type { TextSegment, SystemFontInfo }
  from './src/main/ets/typography/FontFallbackChain.ets';
export { FontFallbackCache, UnicodeBlock, classifyUnicodeBlock }
  from './src/main/ets/typography/FontFallbackCache.ets';

// ==================== Registries & Interfaces ====================

export { BookFormat, RenderStrategy, ParsedBook, ParserRegistry }
  from './src/main/ets/spi/ParserRegistry.ets';
export type { ChapterData, BookParser }
  from './src/main/ets/spi/ParserRegistry.ets';
export { StrategyRegistry } from './src/main/ets/spi/StrategyRegistry.ets';
export type { StrategyRouter }
  from './src/main/ets/spi/StrategyRegistry.ets';

// ==================== Unified Import (导入即解析) & Reversible Export ====================
// 唯一对外可复用的导入入口：所有消费者项目 MUST 经 ImportService.importBook 导入，
// 禁止自行拷贝/解压/解析；导入保留原始源文件以支持可逆导出（逐字节一致）。
export { ImportStatus, IMPORT_INDEX_VERSION }
  from './src/main/ets/import/ImportTypes.ets';
export type { ImportRequest, ImportResult, ImportedBook, ExportArtifact, ImportIndexFile }
  from './src/main/ets/import/ImportTypes.ets';
export type { BatchImportProgress, BatchImportResult }
  from './src/main/ets/import/ImportTypes.ets';
export { DeleteStatus }
  from './src/main/ets/import/ImportTypes.ets';
export type { DeleteResult, DeleteOptions, BookAssociatedDataCleaner }
  from './src/main/ets/import/ImportTypes.ets';
export { ImportedBookStore }
  from './src/main/ets/import/ImportedBookStore.ets';
export { ImportService }
  from './src/main/ets/import/ImportService.ets';

// ==================== TXT Lazy (Phase 9) ====================

export type { TxtLazyDocument, TxtIndexRef, TxtVChapterRef, TxtOldChapterRef }
  from './src/main/ets/types/TxtLazyTypes.ets';

// ==================== Media Overlay ====================

export { createDefaultMediaOverlayState }
  from './src/main/ets/types/MediaOverlayTypes.ets';
export type { MediaOverlayState, HighlightBounds, IMediaOverlayController }
  from './src/main/ets/types/MediaOverlayTypes.ets';
