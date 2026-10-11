/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * ohrengine-pdf-exclusive — Public API
 *
 * This file is the public API surface of the ohrengine-pdf-exclusive HAR module.
 * PDF format exclusive features (parser, renderer, router) are exported
 * from this single entry point. All implementations are stubs that throw
 * NotImplementedError — PDF support is reserved for future work.
 *
 * External consumers MUST import ONLY from this file:
 *   import { PdfParser, PdfRouter } from 'ohrengine-pdf-exclusive';
 */

// ==================== PDF Parser ====================

export { PdfParser } from './src/main/ets/PdfParser.ets';

// ==================== PDF Renderer ====================

export { PdfRenderer } from './src/main/ets/PdfRenderer.ets';

// ==================== PDF Config ====================

export { PdfConfig } from './src/main/ets/PdfConfig.ets';

// ==================== PDF Router ====================

export { PdfRouter } from './src/main/ets/PdfRouter.ets';
