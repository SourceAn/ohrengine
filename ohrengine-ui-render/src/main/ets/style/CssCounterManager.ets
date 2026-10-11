/**
 * CSS 计数器管理器
 * 模拟 counter-reset / counter-increment 行为，支持嵌套列表层级。
 *
 * 内部使用扁平 Map<"counterName:level", value> 存储，
 * 避免 ArkTS 对嵌套泛型的限制。
 */
export class CssCounterManager {
  private counters: Map<string, number> = new Map();

  private key(counterName: string, level: number): string {
    return counterName + ':' + level.toString();
  }

  /**
   * counter-reset: 将指定层级的计数器设为指定值（默认 0）
   */
  public reset(counterName: string, value: number, level: number): void {
    this.counters.set(this.key(counterName, level), value);
  }

  /**
   * counter-increment: 将指定层级的计数器增加 delta（默认 1）
   */
  public increment(counterName: string, delta: number, level: number): void {
    const k: string = this.key(counterName, level);
    const current: number = this.counters.get(k) ?? 0;
    this.counters.set(k, current + delta);
  }

  /**
   * 获取指定层级的计数器当前值
   */
  public getValue(counterName: string, level: number): number {
    const k: string = this.key(counterName, level);
    return this.counters.get(k) ?? 0;
  }

  /**
   * 清空所有计数器（每次完整重排版前调用）
   */
  public resetAll(): void {
    this.counters.clear();
  }
}
