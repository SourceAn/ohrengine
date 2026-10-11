/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * ohrengine-reader — Public API
 *
 * This file is the public API surface of the ohrengine-reader HAR module.
 * The reusable reader host (book opening, page-turn, reader panels) is
 * exported from this single entry point.
 *
 * External consumers MUST import ONLY from this file:
 *   import { ReaderHost } from 'ohrengine-reader';
 */

// ==================== Reader Host ====================

export { ReaderHost } from './src/main/ets/ReaderHost.ets';

// ==================== WordLookupDialog.ets ====================

export { WordLookupDialog } from './src/main/ets/WordLookupDialog.ets';

// ==================== common/ControlSpec.ets ====================

export { ControlSpec } from './src/main/ets/common/ControlSpec.ets';

// ==================== common/IconAssets.ets ====================

export { IconAssets } from './src/main/ets/common/IconAssets.ets';

// ==================== common/MaterialConfig.ets ====================

export { LightIntensity, LightMaterialMode, MaterialConfig } from './src/main/ets/common/MaterialConfig.ets';
// ==================== common/ReaderTheme.ets ====================

export { ReaderTheme, adaptivePanelWidth, isWideScreen, readerIsDark, screenHeightVp, screenWidthVp } from './src/main/ets/common/ReaderTheme.ets';
// ==================== panels/AnnotationPanel.ets ====================

export { AnnotationPanel } from './src/main/ets/panels/AnnotationPanel.ets';

// ==================== panels/ApiConfigPanel.ets ====================

export { ApiConfigPanel } from './src/main/ets/panels/ApiConfigPanel.ets';

// ==================== panels/AutoTurnBar.ets ====================

export { AutoTurnBar } from './src/main/ets/panels/AutoTurnBar.ets';

// ==================== panels/BackgroundStrip.ets ====================

export { BackgroundStrip } from './src/main/ets/panels/BackgroundStrip.ets';

// ==================== panels/FontPanel.ets ====================

export { FontPanel } from './src/main/ets/panels/FontPanel.ets';

// ==================== panels/ReaderControlPanel.ets ====================

export { MenuBarMode, ReaderControlPanel } from './src/main/ets/panels/ReaderControlPanel.ets';

// ==================== panels/ReaderFontSlider.ets ====================

export { ReaderFontSlider } from './src/main/ets/panels/ReaderFontSlider.ets';

// ==================== panels/ReaderLineSpacingSlider.ets ====================

export { ReaderLineSpacingSlider } from './src/main/ets/panels/ReaderLineSpacingSlider.ets';

// ==================== panels/ReaderMenuPanel.ets ====================

export { ReaderMenuPanel } from './src/main/ets/panels/ReaderMenuPanel.ets';

// ==================== panels/ReaderScrubBar.ets ====================

export { ReaderScrubBar, SeekInfo, scrubTrackMaterial } from './src/main/ets/panels/ReaderScrubBar.ets';

// ==================== panels/ReaderSettingsPanel.ets ====================

export { ReaderSettingsPanel } from './src/main/ets/panels/ReaderSettingsPanel.ets';

// ==================== panels/ReaderStatusBar.ets ====================

export { ReaderStatusBar } from './src/main/ets/panels/ReaderStatusBar.ets';

// ==================== panels/SelectionContextMenu.ets ====================

export { SelectionContextMenu } from './src/main/ets/panels/SelectionContextMenu.ets';

// ==================== panels/TocPanel.ets ====================

export { TocPanel } from './src/main/ets/panels/TocPanel.ets';

// ==================== reader/FlipGeometry.ets ====================

export { FlipVisualDirection, FlipCorner, FlipPoint, FlipRectPoints, FlipMath, FlipGeometry } from './src/main/ets/reader/FlipGeometry.ets';

// ==================== reader/FlipPageController.ets ====================

export { FlipPhase, FlipGestureAdapter, FlipPageControllerDeps, FlipPageController } from './src/main/ets/reader/FlipPageController.ets';

// ==================== reader/PageRenderer.ets ====================

export { ReaderViewport, PageRendererDeps, PageRenderer } from './src/main/ets/reader/PageRenderer.ets';

// ==================== reader/ReaderGestureController.ets ====================

export { ReaderGestureControllerDeps, ReaderGestureController } from './src/main/ets/reader/ReaderGestureController.ets';

// ==================== reader/ReaderInfo.ets ====================

export { ChapterPages, ReaderInfo } from './src/main/ets/reader/ReaderInfo.ets';

// ==================== reader/VolumeKeyTurner.ets ====================

export { VolumeKeyTurner } from './src/main/ets/reader/VolumeKeyTurner.ets';

// ==================== reader/SlideTurnController.ets ====================

export { SlideTurnControllerDeps, SlideTurnController } from './src/main/ets/reader/SlideTurnController.ets';

// ==================== service/BatteryMonitor.ets ====================

export { BatteryMonitor } from './src/main/ets/service/BatteryMonitor.ets';

// ==================== utils/FileUtils.ets ====================

export { removeDirRecursive } from './src/main/ets/utils/FileUtils.ets';

// ==================== utils/ReaderSettings.ets ====================

export { ReaderTurnMode, ReaderPageNumberMode, ReaderTextAlign, ReaderSettingsData, createDefaultReaderSettings, FONT_SIZE_LEVELS, LINE_SPACING_LEVELS, ReaderSettings } from './src/main/ets/utils/ReaderSettings.ets';

// ==================== utils/ReaderStatus.ets ====================

export { formatClock, readBattery, readSoc, readCharging } from './src/main/ets/utils/ReaderStatus.ets';

// ==================== utils/ReaderTextUtils.ets ====================

export { ReaderTextUtils } from './src/main/ets/utils/ReaderTextUtils.ets';

// ==================== utils/ReaderThemeUtils.ets ====================

export { ReaderThemeUtils } from './src/main/ets/utils/ReaderThemeUtils.ets';
