/**
 * 统一参数变更总线
 *
 * 任何参数变化都走此总线广播，解耦所有模块：
 *   layoutEngine ← fontSizeChange → pageSplitter ← marginsChange → renderer
 *
 * 使用：
 *   // 订阅
 *   bus.onChange('fontSize', (val) => this.onFontSizeChanged(val));
 *
 *   // 发布
 *   bus.publish('fontSize', 20);
 */
export class ParameterBus {
  private listeners: Map<string, Set<(value: Object) => void>> = new Map();

  /** 订阅参数变更事件 */
  onChange(param: string, cb: (value: Object) => void): void {
    if (!this.listeners.has(param)) {
      this.listeners.set(param, new Set());
    }
    this.listeners.get(param)!.add(cb);
  }

  /** 取消订阅 */
  offChange(param: string, cb: (value: Object) => void): void {
    const set = this.listeners.get(param);
    if (set !== undefined) {
      set.delete(cb);
      if (set.size === 0) {
        this.listeners.delete(param);
      }
    }
  }

  /** 发布参数变更事件 */
  publish(param: string, value: Object): void {
    const set = this.listeners.get(param);
    if (set !== undefined) {
      for (const cb of set) {
        cb(value);
      }
    }
  }

  /** Phase P0-B: 清空全部监听（Session dispose 时调用，解除 UI→bus 闭包持有） */
  clear(): void {
    this.listeners.clear();
  }
}
