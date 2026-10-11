/**
 * CancellationToken — 协作式任务取消令牌（Phase 6）
 *
 * ArkTS SDK 未提供标准 AbortSignal（与 RemoteResourceLoader.RequestCanceller 一致），
 * 自实现最小令牌。约束：仅用于「任务边界」的协作检查（后台 layout/pagination 的
 * 逐章边界、CacheWriter 队列），不中断正在执行的 Knuth-Plass/分页算法本身
 * （算法段短促，任务边界取消已足够防止 P0 被后台任务长期阻塞）。
 */
export class CancellationToken {
  private cancelled: boolean = false;

  /** 请求取消（幂等） */
  cancel(): void {
    this.cancelled = true;
  }

  /** 是否已取消 */
  isCancelled(): boolean {
    return this.cancelled;
  }

  /** 重置为未取消（重开书前调） */
  reset(): void {
    this.cancelled = false;
  }
}