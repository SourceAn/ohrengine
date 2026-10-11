/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * ohrengine-epub — Public API
 *
 * This file is the public API surface of the ohrengine-epub HAR module.
 * EPUB format exclusive features (EPUB container/OPF/NCX/SMIL parsing,
 * cover extraction, and media overlays) are exported from this single
 * entry point.
 *
 * External consumers MUST import ONLY from this file:
 *   import { EpubParser } from 'ohrengine-epub';
 */

// ==================== EPUB Parser ====================

export { EpubParser, guessMimeType,
         MIME_TYPE_XHTML, MIME_TYPE_CSS, MIME_TYPE_IMAGE_JPEG,
         MIME_TYPE_IMAGE_PNG, MIME_TYPE_IMAGE_GIF, MIME_TYPE_IMAGE_SVG,
         MIME_TYPE_NCX, MIME_TYPE_DTBOOK, MIME_TYPE_SMIL,
         MIME_TYPE_PACKAGE_OPF, MIME_TYPE_DTBOOK_ZIP, MIME_TYPE_EPUB }
  from './src/main/ets/parser/EpubParser.ets';
export type { ContainerEntry, OpfData, NcxData, ParseProgressCallback }
  from './src/main/ets/parser/EpubParser.ets';
export { NcxParser } from './src/main/ets/parser/NcxParser.ets';
export { parseXmlToDom, querySelector, querySelectorAll }
  from './src/main/ets/parser/XmlDomParser.ets';
export type { XmlElement }
  from './src/main/ets/parser/XmlDomParser.ets';
export { SmilParser } from './src/main/ets/parser/SmilParser.ets';

// ==================== EPUB Model Types ====================

export { CoverFinder } from './src/main/ets/model/CoverFinder.ets';
export type { CoverResult } from './src/main/ets/model/CoverFinder.ets';
export { CoverHtmlParser } from './src/main/ets/model/CoverHtmlParser.ets';
export type { SmilFile, SmilPar, SmilAudio, SmilTextRef }
  from './src/main/ets/model/MediaOverlayTypes.ets';
export { createDefaultMediaOverlayState }
  from 'ohrengine-common';
export type { MediaOverlayState, HighlightBounds }
  from 'ohrengine-common';

// ==================== Media Overlays ====================

export { MediaOverlayController, PlayerStatus } from './src/main/ets/media/MediaOverlayController.ets';
