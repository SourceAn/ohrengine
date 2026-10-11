/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * ohrengine-cbz-exclusive — Public API
 *
 * This file is the public API surface of the ohrengine-cbz-exclusive HAR module.
 * CBZ format exclusive features (image decoding, sorting, cover extraction)
 * are exported from this single entry point.
 *
 * External consumers MUST import ONLY from this file:
 *   import { CbzParser } from 'ohrengine-cbz-exclusive';
 */

// ==================== CBZ Parser ====================

export { CbzParser } from './src/main/ets/CbzParser.ets';
