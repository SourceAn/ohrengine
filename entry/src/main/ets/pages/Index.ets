/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * Index — 阅读器入口页（薄包装）。
 *
 * 实际阅读器主屏由可复用模块 ohrengine-reader 的 ReaderHost 组件承载；
 * 本页仅负责读取路由参数（bookPath / barMode）并透传给 ReaderHost。
 */

import { ReaderHost, MenuBarMode } from 'ohrengine-reader';
import { OhEngine } from 'ohrengine-ui-render';
import { setVocabularyPageEngine } from './VocabularyListPage.ets';

@Entry
@Component
struct Index {
  @State bookPath: string = '';
  /** 底部菜单栏模式（路由参数：barMode='test' 进单手菜单测试模式） */
  private barMode: MenuBarMode = MenuBarMode.DEBUG;

  aboutToAppear(): void {
    const params: Record<string, Object> | undefined =
      this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params !== undefined) {
      const bp: Object | undefined = params['bookPath'];
      if (bp !== undefined && typeof bp === 'string') {
        this.bookPath = bp;
      }
      const bm: Object | undefined = params['barMode'];
      this.barMode = bm !== undefined && String(bm) === 'test' ? MenuBarMode.TEST : MenuBarMode.DEBUG;
    }
  }

  build() {
    Stack() {
      ReaderHost({
        bookPath: this.bookPath,
        barMode: this.barMode,
        onOpenVocabulary: (engine: OhEngine) => {
          setVocabularyPageEngine(engine);
          this.getUIContext().getRouter().pushUrl({ url: 'pages/VocabularyListPage' });
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}