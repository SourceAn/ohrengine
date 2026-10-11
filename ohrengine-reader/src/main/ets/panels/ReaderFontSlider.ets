import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ControlSpec } from '../common/ControlSpec.ets';

/**
 * 字号档位调节单元（独立胶囊容器内，固定 48px 高）。
 *
 * - 9 档灰色小点 #DCDCDC 均匀分布（禁止横线）；
 * - 档位点两侧建立安全边界（以图示中心为圆心 3px 安全区 + 视觉留白 12vp），
 *   不靠近、不覆盖两侧 A 图示；
 * - 滑块白色圆点直径 28px（与阅读进度条滑块一致），拖动变胶囊形，中心线不变；
 * - 经过每个档位触发轻微阻尼吸附 + 弱触觉反馈（快滑降吸附、慢滑增强）。
 */
@Component
export struct ReaderFontSlider {
  /** 当前档位（1~9，@Prop 与父级配置实时同步，防止回调回弹） */
  @Prop level: number = 1;
  /** 松手 / 点击档位：提交档位（1~9） */
  onLevelCommit: (slot: number) => void = (_slot: number): void => {};
  /** 交互态变化通知（布局不变） */
  onFocusChange: (active: boolean) => void = (_active: boolean): void => {};

  /** 轨道实际宽度（onAreaChange 修正） */
  @State trackW: number = 260;
  /** 拖动（增强交互）态 */
  @State active: boolean = false;
  /** 拖动中的预览档位（0~8 浮点） */
  @State preview: number = 0;
  /** 点击后的动画目标档位（-1 表示无效，未在动画中） */
  @State targetSlot: number = -1;

  private thumbHeld: boolean = false;
  private lastX: number = 0;
  private lastSlotInt: number = -1;
  private lastBuzzAt: number = 0;

  /** 档位数量（9 档） */
  private readonly SLOT_COUNT: number = 9;
  /** 行高固定（统一规范 ControlSpec.ROW_H） */
  private readonly ROW_H: number = ControlSpec.ROW_H;
  private readonly CENTER_Y: number = ControlSpec.CENTER_Y;
  /** 档位点安全边界（统一规范，两侧对称） */
  private readonly SAFE: number = ControlSpec.SAFE;
  /** 档位圆点颜色（更黑的灰） */
  private readonly DOT: number = 6;
  private readonly DOT_COLOR: string = '#B0B4BA';
  /** 滑块尺寸（统一规范，白色圆点） */
  private readonly IDLE_THUMB: number = ControlSpec.THUMB;
  private readonly ACTIVE_THUMB_H: number = ControlSpec.THUMB;
  private readonly TOUCH_BAND: number = ControlSpec.TOUCH_BAND;

  build() {
    Stack() {
      // 9 个档位灰色圆点（均匀分布，两侧保留安全边界）
      ForEach(this.dotIndexes(), (i: number) => {
        Circle()
          .width(this.DOT).height(this.DOT)
          .fill(i === this.currentSlot() ? Color.Transparent : this.DOT_COLOR)
          .position({
            x: this.dotX(i) - this.DOT / 2,
            y: this.CENTER_Y - this.DOT / 2
          })
          .zIndex(2)
      }, (i: number): string => 'dot_' + i)

      // 白色滑块（圆点 28px / 拖动胶囊），中心与档位点同轴线，范围受限
      Row() {
      }
      .width(this.thumbWidth())
      .height(this.thumbHeight())
      .borderRadius(this.thumbHeight() / 2)
      .backgroundColor('#FFFFFF')
      .border({ width: 1.5, color: '#E6FFFFFF' })
      .shadow({ radius: 8, color: '#331F2329', offsetY: 2 })
      .position({
        x: this.thumbCenterX() - this.thumbWidth() / 2,
        y: this.CENTER_Y - this.thumbHeight() / 2
      })
      .zIndex(4)
    }
    .width('100%')
    .height(this.ROW_H)
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

  private dotIndexes(): number[] {
    return [0, 1, 2, 3, 4, 5, 6, 7, 8];
  }

  aboutToAppear(): void {
    // 打开面板时按当前配置恢复选中状态（白色圆点同步到当前档位，不残留最左侧）
    this.preview = this.currentSlot();
    this.targetSlot = -1;
  }

  private handleTouch(event: TouchEvent): void {
    // 拦截触摸冒泡：点击/拖动档位后禁止触发底部菜单栏根容器 onTapOutside
    event.stopPropagation();
    if (event.type === TouchType.Down) {
      const x: number = event.touches[0].x;
      this.lastX = x;
      this.lastSlotInt = -1;
      if (Math.abs(x - this.thumbCenterX()) <= this.TOUCH_BAND / 2) {
        this.thumbHeld = true;
        this.beginDrag(x);
      } else {
        this.thumbHeld = false;
        const slot: number = Math.round(this.valueAt(x));
        // 点击档位：白色圆点平滑移动到所选档位并提交
        this.getUIContext().animateTo({
          duration: 100,
          curve: Curve.Linear,
          onFinish: (): void => {
            this.targetSlot = -1;
          }
        }, () => {
          this.targetSlot = slot;
        });
        this.buzz(10);
        this.onLevelCommit(slot + 1);
      }
      return;
    }
    if (event.type === TouchType.Move) {
      if (!this.thumbHeld) {
        return;
      }
      const x: number = event.touches[0].x;
      const slotFloat: number = this.valueAt(x);
      const dx: number = Math.abs(x - this.lastX);
      const nearest: number = Math.round(slotFloat);
      if (Math.abs(slotFloat - nearest) < 0.3 && nearest !== this.lastSlotInt) {
        this.lastSlotInt = nearest;
        // 实时应用档位：拖动经过档位即同步配置，避免松手后回弹
        this.onLevelCommit(nearest + 1);
        if (dx <= 5) {
          this.getUIContext().animateTo({ duration: 85, curve: Curve.Linear }, () => {
            this.preview = nearest;
          });
          this.buzz(12);
        } else {
          this.preview = slotFloat;
          this.buzz(6);
        }
      } else {
        this.preview = slotFloat;
      }
      this.lastX = x;
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (!this.thumbHeld) {
        return;
      }
      this.thumbHeld = false;
      const final: number = Math.round(this.preview);
      // 松手：圆点平滑吸附到最终档位（提交后与配置同步）
      this.getUIContext().animateTo({
        duration: 110,
        curve: Curve.Linear,
        onFinish: (): void => {
          this.targetSlot = -1;
        }
      }, () => {
        this.preview = final;
        this.active = false;
        this.targetSlot = final;
      });
      this.buzz(8);
      this.onFocusChange(false);
      this.onLevelCommit(final + 1);
    }
  }

  private beginDrag(_x: number): void {
    this.preview = this.currentSlot();
    this.targetSlot = -1;
    this.getUIContext().animateTo({ duration: 180, curve: Curve.Friction }, () => {
      this.active = true;
    });
    this.onFocusChange(true);
  }

  /** 弱触觉反馈（速度自适应、去抖） */
  private buzz(millis: number): void {
    const now: number = Date.now();
    if (now - this.lastBuzzAt < 25) {
      return;
    }
    this.lastBuzzAt = now;
    try {
      vibrator.startVibration({ type: 'time', duration: millis }, { id: 0, usage: 'physicalFeedback' },
        (err: BusinessError) => {
        // 不支持振动时静默忽略（err 忽略）
        });
    } catch (_e) {
      // 忽略振动失败
    }
  }

  private currentSlot(): number {
    return Math.max(0, Math.min(this.SLOT_COUNT - 1, this.level - 1));
  }

  /** 第 i 个档位点的中心 x（两侧保留安全边界） */
  private dotX(i: number): number {
    return this.SAFE + (i / (this.SLOT_COUNT - 1)) * (this.trackW - this.SAFE * 2);
  }

  /** x 坐标 → 档位浮点值（映射到去除安全边界后的有效区域） */
  private valueAt(x: number): number {
    const range: number = Math.max(1, this.trackW - this.SAFE * 2);
    const v: number = (x - this.SAFE) / range * (this.SLOT_COUNT - 1);
    return this.clampSlot(v);
  }

  private thumbCenterX(): number {
    const slot: number = this.displaySlot();
    const cx: number = this.dotX(slot);
    const half: number = this.thumbWidth() / 2;
    return Math.max(half, Math.min(this.trackW - half, cx));
  }

  /**
   * 显示的档位：
   * - 拖拽中跟随手指（preview）；
   * - 点击/松手动画期间跟随动画目标（targetSlot）；
   * - 其余时间严格绑定当前配置值（currentSlot），保证选中状态不丢失、不漂移。
   */
  private displaySlot(): number {
    if (this.active) {
      return this.clampSlot(this.preview);
    }
    if (this.targetSlot >= 0) {
      return this.targetSlot;
    }
    return this.currentSlot();
  }

  private thumbWidth(): number {
    return this.active ? this.thumbHeight() * 1.5 : this.IDLE_THUMB;
  }

  private thumbHeight(): number {
    return this.active ? this.ACTIVE_THUMB_H : this.IDLE_THUMB;
  }

  private clampSlot(v: number): number {
    return Math.max(0, Math.min(this.SLOT_COUNT - 1, v));
  }
}