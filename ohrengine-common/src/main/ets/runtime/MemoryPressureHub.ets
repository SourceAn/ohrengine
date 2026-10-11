/**
 * MemoryPressureHub — 应用内存压力广播（Phase 3, L3 memory pressure）
 *
 * 用途：HarmonyOS 的 onMemoryLevel 是 UIAbility/AbilityStage 生命周期回调，
 * 阅读引擎（ReaderHost 内嵌页面）无法直接接收。用一个小型静态订阅点桥接：
 *   EntryAbility.onMemoryLevel(level) → MemoryPressureHub.publish(level)
 *   OhEngineCore 注册订阅 → shrinkMemoryCaches(level)
 *
 * 保持极简：单一静态订阅位，无事件队列；lastLevel 供轮询/调试。
 */
type MemoryLevelListener = (level: number) => void;

export class MemoryPressureHub {
  private static listener: MemoryLevelListener | undefined = undefined;
  private static lastLevel: number = 0;

  /** 引擎侧注册（覆盖旧订阅，单例语义） */
  static subscribe(cb: MemoryLevelListener): void {
    MemoryPressureHub.listener = cb;
  }

  /** 引擎取消订阅 */
  static unsubscribe(): void {
    MemoryPressureHub.listener = undefined;
  }

  /** Ability 侧发布（onMemoryLevel 回调） */
  static publish(level: number): void {
    MemoryPressureHub.lastLevel = level;
    if (MemoryPressureHub.listener !== undefined) {
      try {
        MemoryPressureHub.listener(level);
      } catch (_e) {
      }
    }
  }

  /** 最近一次内存级别（调试/工具用） */
  static getLastLevel(): number {
    return MemoryPressureHub.lastLevel;
  }
}