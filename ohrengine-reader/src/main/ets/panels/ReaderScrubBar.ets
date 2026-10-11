import { uiMaterial, curves } from '@kit.ArkUI';
import { ControlSpec } from '../common/ControlSpec.ets';
import { MaterialConfig } from '../common/MaterialConfig.ets';

/**
 * 阅读进度条（固定高度，三态高度/Y 完全一致）。
 *
 * 核心约束：
 * - 默认 / 拖动 / 拖动结束：进度条高度恒定，始终固定在同一个水平线上，
 *   禁止加粗、放大、改变 Y 坐标。
 * - 滑块白色圆点直径 28px；进度条宽度/滑块视觉比例协调（禁止进度条远大于滑块）。
 * - 颜色仅两种：#DCDCDC（已读） / #F5F5F5（未读），无渐变、无主题联动。
 * - 只显示已读 + 未读两个颜色区域，不显示中间横线；滑块覆盖在进度区域上。
 * - 拖动时滑块变胶囊形，弹性动画仅作用于形态；中心移动范围限于有效区域，
 *   不越界、不覆盖左右文字。
 * - 拖动浮层：黑色 80% 胶囊，位于进度条正上方（不重叠、不遮挡），
 *   两行内容（真实章节名 / 页码），水平居中于面板竖直中心线。
 */
@Component
export struct ReaderScrubBar {
  /** 当前进度 0~1（@Prop 与父级配置实时同步，防止拖动后回弹） */
  @Prop value: number = 0;
  /** 查询指定进度下的章节名 / 页码信息（Index 提供） */
  onQuerySeekInfo: (v: number) => SeekInfo = (_v: number): SeekInfo => {
    return { title: '', pageNum: 0, totalPages: 0 };
  };
  /** 松手 / 点击遗留圆点 / 点击轨道：跳转指定进度 */
  onCommit: (v: number) => void = (_v: number): void => {};
  /** 交互态变化通知（面板布局不受影响） */
  onScrubStateChange: (active: boolean) => void = (_active: boolean): void => {};

  /** 轨道实际像素宽度（onAreaChange 修正） */
  @State trackW: number = 280;
  /** 是否正在拖动（滑块变胶囊并显示浮层） */
  @State active: boolean = false;
  /** 拖动中的预览值 */
  @State preview: number = 0;
  /** 弹性形变（仅作用于滑块形态） */
  @State jellyX: number = 1;
  @State jellyY: number = 1;
  /** 浮层文案 */
  @State seekTitle: string = '';
  @State seekPageNum: number = 1;
  @State seekTotal: number = 1;

  /** 是否已命中滑块 */
  private thumbHeld: boolean = false;
  private lastX: number = 0;

  /** 组件行高固定（统一规范 ControlSpec.ROW_H） */
  private readonly STACK_H: number = ControlSpec.ROW_H;
  /** 进度条高度（统一规范，任何状态禁止变化） */
  private readonly TRACK_H: number = ControlSpec.TRACK_H;
  private readonly TRACK_CENTER_Y: number = ControlSpec.CENTER_Y;
  /** 滑块尺寸（白色圆点，与字号/行距滑杆统一） */
  private readonly IDLE_THUMB: number = ControlSpec.THUMB;
  private readonly ACTIVE_THUMB_H: number = ControlSpec.THUMB;
  private readonly TOUCH_BAND: number = ControlSpec.TOUCH_BAND;
  private readonly POPUP_GAP: number = 10;
  /** 已读 / 未读颜色（固定参数：#66645D 25% / #CBCBCB 35%，同一胶囊裁剪） */
  private readonly READ_COLOR: string = '#4066645D';
  private readonly UNREAD_COLOR: string = '#59CBCBCB';

  build() {
    Stack() {
      // 材质底层：API 26 沉浸光感 / API 24 灰底平替（scrubTrackBg 模式感知）
      Row() {
      }
      .width(this.trackW)
      .height(this.TRACK_H)
      .borderRadius(this.TRACK_H / 2)
      .backgroundColor(MaterialConfig.scrubTrackBg())
      .systemMaterial(scrubTrackMaterial())
      .position({ x: 0, y: this.TRACK_CENTER_Y - this.TRACK_H / 2 })
      .zIndex(0)

      // 未阅读 + 已阅读统一裁剪容器：
      // 两端半圆折叠，已读区域以轨道有效宽度计算并按胶囊边界裁剪，
      // 拖动到 0% / 100% 时不会超出胶囊边界、两端半圆不被撑宽。
      Stack({ alignContent: Alignment.Start }) {
        Row() {
        }
        .width(this.fillWidth())
        .height(this.TRACK_H)
        .borderRadius(this.TRACK_H / 2)
        .backgroundColor(this.READ_COLOR)
      }
      .width(this.trackW)
      .height(this.TRACK_H)
      .backgroundColor(this.UNREAD_COLOR)
      .borderRadius(this.TRACK_H / 2)
      .clip(true)
      .position({ x: 0, y: this.TRACK_CENTER_Y - this.TRACK_H / 2 })
      .zIndex(1)

      // 白色滑块（圆点 28px / 拖动胶囊），覆盖在进度区域上，中心与进度条一致
      Row() {
      }
      .width(this.thumbWidth())
      .height(this.thumbHeight())
      .borderRadius(this.thumbHeight() / 2)
      .backgroundColor('#FFFFFF')
      .border({ width: 1.5, color: '#B3FFFFFF' })
      .shadow({ radius: 8, color: '#331F2329', offsetY: 2 })
      .scale({ x: this.jellyX, y: this.jellyY })
      .position({
        x: this.thumbCenterX() - this.thumbWidth() / 2,
        y: this.TRACK_CENTER_Y - this.thumbHeight() / 2
      })
      .zIndex(4)

      // 章节信息弹窗：进度条正上方（不重叠/不遮挡），水平居中
      if (this.active) {
        Column({ space: 2 }) {
          Text(this.seekTitle)
            .fontSize(13).fontColor('#FFFFFF')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .width('100%')
          Text(this.seekPageNum + ' / ' + this.seekTotal)
            .fontSize(12).fontColor('#E3E6EA')
            .textAlign(TextAlign.Center)
        }
        .width(this.popupW())
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor('#CC000000')
        .borderRadius(15)
        .shadow({ radius: 14, color: '#40000000', offsetY: 4 })
        .position({
          x: Math.max(0, (this.trackW - this.popupW()) / 2),
          y: this.TRACK_CENTER_Y - this.TRACK_H / 2 - this.POPUP_GAP - this.popupH()
        })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 })) as TransitionEffect)
        .zIndex(10)
      }
    }
    .width('100%')
    .height(this.STACK_H)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w: number = newArea.width as number;
      if (w > 0) {
        this.trackW = w;
      }
    })
    .onTouch((event: TouchEvent) => {
      this.handleTouch(event);
    })
  }

  private handleTouch(event: TouchEvent): void {
    // 拦截触摸冒泡：拖动/点击进度条提交跳转后，禁止触发底部菜单栏根容器 onTapOutside
    event.stopPropagation();
    if (event.type === TouchType.Down) {
      const x: number = event.touches[0].x;
      this.lastX = x;
      if (Math.abs(x - this.thumbCenterX()) <= this.TOUCH_BAND / 2) {
        this.thumbHeld = true;
        this.beginScrub(x);
      } else {
        this.thumbHeld = false;
        this.onCommit(this.clampValue(x / this.trackW));
      }
      return;
    }
    if (event.type === TouchType.Move) {
      if (!this.thumbHeld) {
        return;
      }
      const x: number = event.touches[0].x;
      const v: number = this.clampValue(x / this.trackW);
      this.preview = v;
      this.syncSeekInfo(v);
      this.jelly(x);
      this.lastX = x;
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (!this.thumbHeld) {
        return;
      }
      this.thumbHeld = false;
      this.getUIContext().animateTo({
        duration: 220,
        curve: Curve.Friction
      }, () => {
        this.active = false;
        this.jellyX = 1;
        this.jellyY = 1;
      });
      this.onScrubStateChange(false);
      this.onCommit(this.preview);
    }
  }

  /** 按住滑块：进入拖动态（进度条高度/Y 均不变，仅滑块与浮层变化） */
  private beginScrub(x: number): void {
    this.preview = this.clampValue(this.value);
    this.syncSeekInfo(this.preview);
    this.getUIContext().animateTo({
      duration: 220,
      curve: Curve.Friction
    }, () => {
      this.active = true;
    });
    this.onScrubStateChange(true);
    this.jelly(x);
  }

  private syncSeekInfo(v: number): void {
    const info: SeekInfo = this.onQuerySeekInfo(v);
    this.seekTitle = info.title;
    this.seekPageNum = info.pageNum;
    this.seekTotal = info.totalPages;
  }

  /** 弹性形变（仅形态，位置保持受限） */
  private jelly(x: number): void {
    const dx: number = x - this.lastX;
    const mag: number = Math.min(0.35, Math.abs(dx) / 120);
    this.jellyX = 1 + mag;
    this.jellyY = 1 - mag * 0.5;
    this.getUIContext().animateTo({
      duration: 220,
      curve: curves.springMotion(0.3, 0.72)
    }, () => {
      this.jellyX = 1;
      this.jellyY = 1;
    });
  }

  private thumbCenterX(): number {
    const v: number = this.clampValue(this.active ? this.preview : this.value);
    const cx: number = v * this.trackW;
    return this.clampCenter(cx, this.thumbWidth() / 2);
  }

  private thumbWidth(): number {
    return this.active ? this.thumbHeight() * 1.5 : this.IDLE_THUMB;
  }

  private thumbHeight(): number {
    return this.active ? this.ACTIVE_THUMB_H : this.IDLE_THUMB;
  }

  private fillWidth(): number {
    return this.clampValue(this.active ? this.preview : this.value) * this.trackW;
  }

  /** 中心点收纳到有效范围 [half, trackW - half] */
  private clampCenter(cx: number, half: number): number {
    return Math.max(half, Math.min(this.trackW - half, cx));
  }

  private popupW(): number {
    const len: number = this.seekTitle.length + String(this.seekPageNum).length + String(this.seekTotal).length;
    return Math.max(160, Math.min(this.trackW, len * 7 + 48));
  }

  private popupH(): number {
    return 56;
  }

  private clampValue(v: number): number {
    return Math.max(0, Math.min(1, v));
  }
}

/** 拖动浮层信息 */
export interface SeekInfo {
  title: string;
  pageNum: number;
  totalPages: number;
}

/**
 * 轨道材质（供 systemMaterial 使用）。
 * API 26 设备：沉浸式系统材质（原始实现，保留不动）；
 * API 24 / 不支持沉浸光感设备：返回 undefined，由 build() 走底色平替。
 * 注意：必须惰性生成（模块顶层直接 new ImmersiveMaterial 会在低版本设备加载时崩溃）。
 */
export function scrubTrackMaterial(): uiMaterial.Material | undefined {
  if (!MaterialConfig.isImmersiveSupported()) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    materialColor: 'rgba(116,124,132,0.24)',
    colorInvert: false,
    applyShadow: false,
    interactive: false,
    lightEffect: undefined
  });
}