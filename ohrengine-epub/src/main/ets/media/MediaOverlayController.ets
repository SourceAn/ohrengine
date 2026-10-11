/**
 * MediaOverlayController — EPUB3 媒体叠加控制器
 *
 * 职责：
 * - 管理 AVPlayer 生命周期（初始化、播放、暂停、停止）
 * - 将 SMIL 段落绑定到音频时间片
 * - 维护高亮状态（当前高亮文本片段的位置）
 */

import { SmilFile, SmilPar } from '../model/MediaOverlayTypes.ets';
import { MediaOverlayState, HighlightBounds, createDefaultMediaOverlayState,
  IMediaOverlayController } from 'ohrengine-common';

/**
 * MediaOverlay 播放器状态枚举
 */
export enum PlayerStatus {
  IDLE = 'idle',
  PLAYING = 'playing',
  PAUSED = 'paused',
  STOPPED = 'stopped'
}

/**
 * 媒体叠加控制器
 */
export class MediaOverlayController implements IMediaOverlayController {
  private avPlayer: Object | null = null;
  private status: PlayerStatus = PlayerStatus.IDLE;
  private state: MediaOverlayState;

  private currentSmil: SmilFile | null = null;
  private timerId: number = -1;
  private currentParStartTime: number = 0;

  constructor() {
    this.state = createDefaultMediaOverlayState();
  }

  /**
   * 获取当前 MediaOverlayState
   */
  public getState(): MediaOverlayState {
    return this.state;
  }

  /**
   * 获取当前播放状态
   */
  public getStatus(): PlayerStatus {
    return this.status;
  }

  /**
   * 加载 SMIL 文件并准备播放
   *
   * @param smil      SMIL 文件结构
   * @param basePath  音频文件基础路径（用于拼接完整 URL）
   */
  public loadSmil(smil: SmilFile, basePath: string): void {
    this.currentSmil = smil;
    this.state.currentSmil = smil.src;
    this.state.totalPars = smil.pars.length;
    this.state.currentParIndex = 0;
    this.state.isPlaying = false;
    this.state.progress = 0;
    this.state.highlightBounds = [];
    this.status = PlayerStatus.IDLE;
  }

  /**
   * 开始播放媒体叠加
   */
  public async play(): Promise<void> {
    const smil: SmilFile | null = this.currentSmil;
    if (smil === null || smil.pars.length === 0) {
      return;
    }

    this.state.isPlaying = true;
    this.status = PlayerStatus.PLAYING;
    await this.playPar(this.state.currentParIndex);
  }

  /**
   * 暂停播放
   */
  public pause(): void {
    this.state.isPlaying = false;
    this.status = PlayerStatus.PAUSED;
    this.clearTimer();
    if (this.avPlayer !== null) {
      // AVPlayer 暂停 — 通过相应 API 调用
    }
  }

  /**
   * 停止播放并重置状态
   */
  public stop(): void {
    this.state.isPlaying = false;
    this.status = PlayerStatus.STOPPED;
    this.clearTimer();
    this.stopAvPlayer();
    this.state.currentParIndex = 0;
    this.state.progress = 0;
    this.state.highlightBounds = [];
  }

  /**
   * 跳转到指定段落序号
   */
  public async seekTo(parIndex: number): Promise<void> {
    if (this.currentSmil === null) {
      return;
    }
    if (parIndex < 0 || parIndex >= this.currentSmil.pars.length) {
      return;
    }

    this.stop();
    this.state.currentParIndex = parIndex;
    if (this.state.isPlaying) {
      await this.playPar(parIndex);
    }
  }

  /**
   * 重置状态（章节切换时调用）
   */
  public reset(): void {
    this.stop();
    this.currentSmil = null;
    this.state = createDefaultMediaOverlayState();
  }

  /**
   * 释放 AVPlayer 资源（页面销毁时调用）
   */
  public release(): void {
    this.stop();
    this.avPlayer = null;
  }

  /**
   * 播放指定段落
   */
  private async playPar(parIndex: number): Promise<void> {
    if (this.currentSmil === null) {
      return;
    }
    const par: SmilPar = this.currentSmil.pars[parIndex];
    this.state.currentParIndex = parIndex;
    this.currentParStartTime = Date.now();

    // 更新高亮状态
    this.state.highlightBounds = [];

    // 启动定时器模拟段落时长
    this.clearTimer();
    const durationMs: number = par.duration * 1000;

    this.timerId = setTimeout(() => {
      this.onParEnd();
    }, durationMs);

    // 播放音频
    await this.playAudio(par.audio.src, par.audio.clipBegin, par.audio.clipEnd);
  }

  /**
   * 段落播放结束回调
   */
  private onParEnd(): void {
    if (this.currentSmil === null) {
      return;
    }

    this.state.highlightBounds = [];

    const nextIdx: number = this.state.currentParIndex + 1;
    const total: number = this.currentSmil.pars.length;
    if (nextIdx < total) {
      this.state.currentParIndex = nextIdx;
      this.state.progress = nextIdx / total;
      if (this.state.isPlaying) {
        this.playPar(nextIdx);
      }
    } else {
      // 所有段落播放完毕
      this.state.isPlaying = false;
      this.status = PlayerStatus.STOPPED;
      this.state.progress = 1;
    }
  }

  /**
   * 播放音频片段
   *
   * 使用 @ohos.multimedia.media 的 AVPlayer
   * 当前为占位实现 — 由真实 AVPlayer API 替换。
   */
  private async playAudio(src: string, clipBegin: number, clipEnd: number): Promise<void> {
    try {
      if (this.avPlayer === null) {
        // const media = requireNapi('multimedia.media');
        // this.avPlayer = await media.createAVPlayer();
      }
      // 实际播放逻辑：设置 fdSrc/url，seek 到 clipBegin，在 clipEnd 停止
    } catch (e) {
      // 播放失败时回退
      this.state.isPlaying = false;
      this.status = PlayerStatus.STOPPED;
    }
  }

  /**
   * 停止 AVPlayer
   */
  private stopAvPlayer(): void {
    try {
      if (this.avPlayer !== null) {
        // (this.avPlayer as AVPlayer).stop();
        // (this.avPlayer as AVPlayer).reset();
      }
    } catch (_e) {
    }
  }

  /**
   * 清除高亮定时器
   */
  private clearTimer(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  /**
   * 设置高亮边界（由外部在渲染时提供）
   *
   * @param bounds 当前页面上需要高亮的元素边界列表
   */
  public setHighlightBounds(bounds: HighlightBounds[]): void {
    this.state.highlightBounds = bounds;
  }
}
