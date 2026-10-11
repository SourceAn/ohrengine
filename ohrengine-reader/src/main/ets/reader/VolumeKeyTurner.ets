/*
 * Copyright (c) 2026 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * VolumeKeyTurner — 音量键翻页订阅器（ohrengine-reader 可复用能力）。
 *
 * 基于 inputConsumer('keyPressed') 系统级按键监听：
 *  - 音量下（KEYCODE_VOLUME_DOWN）= 下一页（FORWARD）；
 *  - 音量上（KEYCODE_VOLUME_UP）= 上一页（BACKWARD）；
 *  - 仅在应用处于前台焦点窗口时回调；
 *  - 无需申请权限；action=1（按下）且 isRepeat=false（不重复上报）。
 *
 * 注意：部分系统（已验证 HarmonyOS 6.1.1 真机）对同一个 callback 的多个
 * 音量键订阅只保留一个；因此音量下/音量上必须使用**两个独立回调**分别订阅。
 *
 * 使用方式（宿主阅读页）：
 *   const turner = new VolumeKeyTurner();
 *   turner.start((d) => { engine.turnPage(d); });
 *   // 页面隐藏/销毁时
 *   turner.stop();
 */
import { inputConsumer, KeyCode } from '@kit.InputKit';
import type { KeyEvent } from '@kit.InputKit';
import { TurnDirection } from 'ohrengine-common';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'VolumeKeyTurner';

export class VolumeKeyTurner {
  private cbDown: Callback<KeyEvent> | null = null;
  private cbUp: Callback<KeyEvent> | null = null;
  private onTurn: ((direction: TurnDirection) => void) | null = null;

  /** 是否已订阅 */
  isActive(): boolean {
    return this.cbDown !== null || this.cbUp !== null;
  }

  /**
   * 订阅音量键翻页（幂等：重复调用先退订再订阅）。
   * @param onTurn 翻页回调（FORWARD=音量下/下一页，BACKWARD=音量上/上一页）
   */
  start(onTurn: (direction: TurnDirection) => void): void {
    this.stop();
    this.onTurn = onTurn;

    const cbDown: Callback<KeyEvent> = (event: KeyEvent): void => {
      hilog.info(0x0000, TAG, 'keyPressed event received, keyCode=%{public}d', event.key.code);
      if (this.onTurn === null) {
        return;
      }
      try {
        if (event.key.code === KeyCode.KEYCODE_VOLUME_DOWN) {
          hilog.info(0x0000, TAG, 'volume down -> FORWARD');
          this.onTurn(TurnDirection.FORWARD);
        }
      } catch (e) {
        hilog.warn(0x0000, TAG, 'handle DOWN failed: %{public}s', JSON.stringify(e));
      }
    };
    const cbUp: Callback<KeyEvent> = (event: KeyEvent): void => {
      hilog.info(0x0000, TAG, 'keyPressed event received, keyCode=%{public}d', event.key.code);
      if (this.onTurn === null) {
        return;
      }
      try {
        if (event.key.code === KeyCode.KEYCODE_VOLUME_UP) {
          hilog.info(0x0000, TAG, 'volume up -> BACKWARD');
          this.onTurn(TurnDirection.BACKWARD);
        }
      } catch (e) {
        hilog.warn(0x0000, TAG, 'handle UP failed: %{public}s', JSON.stringify(e));
      }
    };
    this.cbDown = cbDown;
    this.cbUp = cbUp;

    // 音量下 / 音量上 使用两个独立回调分别订阅（同一回调多键订阅在部分系统失效）
    try {
      inputConsumer.on('keyPressed', {
        key: KeyCode.KEYCODE_VOLUME_DOWN,
        action: 1,
        isRepeat: false
      }, cbDown);
      hilog.info(0x0000, TAG, 'volume DOWN subscribed');
    } catch (e) {
      hilog.error(0x0000, TAG, 'subscribe VOLUME_DOWN failed: %{public}s', JSON.stringify(e));
      this.cbDown = null;
    }
    try {
      inputConsumer.on('keyPressed', {
        key: KeyCode.KEYCODE_VOLUME_UP,
        action: 1,
        isRepeat: false
      }, cbUp);
      hilog.info(0x0000, TAG, 'volume UP subscribed');
    } catch (e) {
      hilog.error(0x0000, TAG, 'subscribe VOLUME_UP failed: %{public}s', JSON.stringify(e));
      this.cbUp = null;
    }
    if (this.cbDown !== null || this.cbUp !== null) {
      hilog.info(0x0000, TAG, 'volume key subscription started');
    }
  }

  /** 退订（页面隐藏/销毁时必须成对调用） */
  stop(): void {
    if (this.cbDown !== null) {
      try {
        inputConsumer.off('keyPressed', this.cbDown);
      } catch (e) {
        hilog.warn(0x0000, TAG, 'inputConsumer.off(DOWN) failed: %{public}s', JSON.stringify(e));
      }
      this.cbDown = null;
    }
    if (this.cbUp !== null) {
      try {
        inputConsumer.off('keyPressed', this.cbUp);
      } catch (e) {
        hilog.warn(0x0000, TAG, 'inputConsumer.off(UP) failed: %{public}s', JSON.stringify(e));
      }
      this.cbUp = null;
    }
    this.onTurn = null;
  }
}