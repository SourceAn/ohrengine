/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * ohrengine-parsers — Public API
 *
 * This file is the public API surface of the ohrengine-parsers HAR module.
 * All format parsers and related utilities are exported from this single
 * entry point.
 *
 * External consumers MUST import ONLY from this file:
 *   import { CssParser, HtmlParser } from 'ohrengine-parsers';
 *
 * NOTE: TxtParser and CbzParser were moved to the format-exclusive modules
 * (ohrengine-txt-exclusive / ohrengine-cbz-exclusive) in the multi-module
 * refactor. Import them from those modules instead:
 *   import { TxtParser } from 'ohrengine-txt-exclusive';
 *   import { CbzParser } from 'ohrengine-cbz-exclusive';
 *
 * EpubParser and the EPUB/SMIL tooling (NcxParser, SmilParser,
 * XmlDomParser, CoverFinder, CoverHtmlParser, MediaOverlayTypes,
 * MediaOverlayController) were moved to ohrengine-epub in the same
 * refactor. Import them from that module instead:
 *   import { EpubParser } from 'ohrengine-epub';
 */

// ==================== HTML Parser ====================

export { HtmlParser, toRoman, generateMarker,
         getLevelDefaultMarkerType, estimateMarkerWidth, createRenderNode }
  from './src/main/ets/html/HtmlParser.ets';
export type { StyleMapper, CompiledStylesheet }
  from './src/main/ets/html/HtmlParser.ets';
export type { RubyPair, TableElement, TableRow, TableCell }
  from 'ohrengine-common';
export { ListStyleType }
  from './src/main/ets/html/HtmlParser.ets';

// ==================== CSS Parsers ====================

export { CssParser, createCssRuleSet, createStyleSheet }
  from './src/main/ets/css/CssParser.ets';
export type { CssSelector, CssRule, CssDeclaration, CssRuleSet,
              MediaQuery, StyleSheet }
  from './src/main/ets/css/CssParser.ets';
export { SelectorType, StyleSource }
  from './src/main/ets/css/CssParser.ets';
export { FontFaceParser } from './src/main/ets/css/FontFaceParser.ets';
