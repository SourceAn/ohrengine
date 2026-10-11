/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * ohrengine-txt-exclusive — Public API
 *
 * This file is the public API surface of the ohrengine-txt-exclusive HAR module.
 * TXT format exclusive features (chapter detection, paragraph splitting)
 * are exported from this single entry point.
 *
 * External consumers MUST import ONLY from this file:
 *   import { TxtParser } from 'ohrengine-txt-exclusive';
 */

// ==================== TXT Parser ====================

export { TxtParser } from './src/main/ets/TxtParser.ets';
export { TxtConfig } from './src/main/ets/TxtConfig.ets';
export { TxtEncodingDetector } from './src/main/ets/TxtEncodingDetector.ets';
export { TxtChapterDetector, TxtChapterBlock } from './src/main/ets/TxtChapterDetector.ets';
export { TxtParagraphSplitter } from './src/main/ets/TxtParagraphSplitter.ets';

// ==================== TXT Lazy (Phase 9) ====================

export { TxtLazyConfig } from './src/main/ets/TxtLazyConfig.ets';
export { TxtIndexBuilder } from './src/main/ets/TxtIndexBuilder.ets';
export { TxtIndexData } from './src/main/ets/TxtIndexData.ets';
export type { TxtChunkData, TxtOldChapterData, TxtVChapterData } from './src/main/ets/TxtIndexData.ets';
export { TxtChunkReader } from './src/main/ets/TxtChunkReader.ets';
export { TxtDocument } from './src/main/ets/TxtDocument.ets';