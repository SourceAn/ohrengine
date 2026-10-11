/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * ohrengine-feature — Public API
 *
 * This file is the public API surface of the ohrengine-feature HAR module.
 * Reader feature models/services (dictionary, vocabulary, annotation,
 * bookmark, theme, selection, history, search) are exported from this
 * single entry point.
 *
 * External consumers MUST import ONLY from this file:
 *   import { FeatureManager, ThemeManager, BookmarkStorage } from 'ohrengine-feature';
 */

// ==================== Dictionary ====================

export { DictionaryProvider, BuiltinDictionary, FreeDictionaryAPI,
         TranslationProvider, BuiltinTranslationProvider }
  from './src/main/ets/dictionary/DictionaryService.ets';
export { DictionaryScheduler, DictionaryConfigManager, OnlineApiConfig,
         CustomAPIProvider }
  from './src/main/ets/dictionary/DictionaryScheduler.ets';

// ==================== Vocabulary ====================

export { VocabularyBook } from './src/main/ets/vocabulary/VocabularyBook.ets';

// ==================== Annotation ====================

export { AnnotationStorage } from './src/main/ets/annotation/AnnotationStorage.ets';
export { AnnotationExporter, parseCustomTemplate }
  from './src/main/ets/annotation/AnnotationExporter.ets';
export type { TemplateContext }
  from './src/main/ets/annotation/AnnotationExporter.ets';

// ==================== Bookmark ====================

export { Bookmark } from './src/main/ets/bookmark/Bookmark.ets';
export { BookmarkStorage } from './src/main/ets/bookmark/BookmarkStorage.ets';

// ==================== Reading History ====================

export { ReadingHistoryManager } from './src/main/ets/history/ReadingHistory.ets';
export type { ReadingRecord, RecordPosition }
  from './src/main/ets/history/ReadingHistory.ets';

// ==================== Theme ====================
// ARCH-003: Theme/FontTheme 纯类型与 PRESET_THEMES/FONT_THEMES 常量已下沉到
// ohrengine-common（types/ThemeTypes.ets），此处从 common re-export 保持兼容；
// ThemeManager / FontThemeManager 状态类仍在 feature。

export { ThemeManager }
  from './src/main/ets/theme/ThemeManager.ets';
export type { Theme, FontTheme }
  from 'ohrengine-common';
export { PRESET_THEMES, FONT_THEMES }
  from 'ohrengine-common';
export { ThemePreferenceStorage }
  from './src/main/ets/theme/ThemePreferenceStorage.ets';
export { FontThemeManager }
  from './src/main/ets/theme/FontThemeManager.ets';

// ==================== Text Selection ====================

export { SelectionRenderer, SelectionGestureHandler, ContextMenuManager, HitTester }
  from './src/main/ets/selection/TextSelection.ets';
export type { SelectionRange }
  from './src/main/ets/selection/TextSelection.ets';

// ==================== Search ====================

export { FullTextSearch } from './src/main/ets/search/SearchIndex.ets';
export type { SearchResult }
  from './src/main/ets/search/SearchIndex.ets';

// ==================== Word Entry ====================

export { WordEntry } from './src/main/ets/model/WordEntry.ets';
export type { VocabularyItem }
  from './src/main/ets/model/WordEntry.ets';

// ==================== Feature Manager ====================

export { FeatureManager } from './src/main/ets/FeatureManager.ets';
