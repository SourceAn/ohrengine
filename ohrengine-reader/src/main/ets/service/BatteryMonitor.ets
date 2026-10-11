import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { readCharging, readSoc } from '../utils/ReaderStatus.ets';

/**
 * BatteryMonitor — 系统电池状态实时订阅器（从 Index 拆分）。
 * 通过 COMMON_EVENT_BATTERY_CHANGED 监听电量/充电变化，回调最新状态。
 */
export class BatteryMonitor {
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private onChange: (charging: boolean, soc: number) => void = () => {};
  /** 页面销毁标记：随页面生命周期置位，回调不再上抛 */
  private destroyed: boolean = false;

  /** 注册状态变更回调 */
  onBatteryChange(cb: (charging: boolean, soc: number) => void): void {
    this.onChange = cb;
  }

  setDestroyed(d: boolean): void {
    this.destroyed = d;
  }

  /** 立即读取一次 + 订阅系统电池事件（电量/充电实时同步） */
  start(): void {
    this.onChange(readCharging(), readSoc());
    try {
      const subscribeInfo: commonEventManager.CommonEventSubscribeInfo = {
        events: [commonEventManager.Support.COMMON_EVENT_BATTERY_CHANGED]
      };
      commonEventManager.createSubscriber(subscribeInfo,
        (err: BusinessError, subscriber: commonEventManager.CommonEventSubscriber) => {
          if (err) {
            return;
          }
          this.subscriber = subscriber;
          this.onChange(readCharging(), readSoc());
          commonEventManager.subscribe(this.subscriber,
            (_subErr: BusinessError, _data: commonEventManager.CommonEventData) => {
              if (this.destroyed) {
                return;
              }
              this.onChange(readCharging(), readSoc());
            });
        });
    } catch (e) {
    }
  }

  /** 取消订阅（会话结束防泄漏） */
  stop(): void {
    if (this.subscriber !== null) {
      const sub: commonEventManager.CommonEventSubscriber = this.subscriber;
      this.subscriber = null;
      commonEventManager.unsubscribe(sub);
    }
  }
}