/*
 * flip_state_machine.h — 翻页显式状态机（native 唯一真源，0.10/0.12/0.13）
 *
 * 职责：
 *  - 显式枚举状态机（Idle/Dragging/SettlingToComplete/SettlingToRebound/
 *    Cancelling/ReboundRecovery），完整实现 0.10 状态转移表；
 *  - operationToken 生成（进程内单调递增，[1, 2^31-1]，0=无效）与双向校验；
 *  - 纹理事务（TextureTransaction）登记/保留期/释放（0.12）；
 *  - 完成/回弹阈值判定与末速度估算（唯一归属，0.6，配合 spring_damper）；
 *  - 900ms 兜底超时（强制 B1 + pendingResult 降级为 rebound，0.10/0.12）；
 *  - ReboundRecovery（合成回弹，复用保留期纹理事务，0.10/0.12）；
 *  - Required Change 1 的 B1→B3 提交屏障 guard（PendingCommit 窗口禁新手势）；
 *  - Required Change 5 的 Surface 销毁清理矩阵。
 *
 * ⚠️ 本头文件及其 .cpp **禁止包含任何 GL/EGL/OHOS 头文件**（纹理句柄使用
 * 不透明整数类型 TextureHandle），保证 host 端离线单测可编译。
 */
#pragma once

#include <cstdint>
#include <functional>
#include <vector>
#include <map>
#include <mutex>

#include "../geometry/curl_geometry.h"
#include "spring_damper.h"

namespace flipgl {

/** 显式翻页状态枚举（0.10，唯一状态源） */
enum class FlipState : int32_t {
  IDLE = 0,
  DRAGGING = 1,
  SETTLING_TO_COMPLETE = 2,
  SETTLING_TO_REBOUND = 3,
  CANCELLING = 4,
  REBOUND_RECOVERY = 5,
};

/** 手势最终结果（完成回调 payload 的 result 字段语义） */
enum class FlipResult : int32_t {
  COMPLETED = 0,
  REBOUND = 1,
};

/** beginGesture / beginReboundRecovery 失败原因（0.6） */
enum class FailureReason : int32_t {
  NONE = 0,
  TSFN_UNAVAILABLE = 1,
  OPERATION_IN_PROGRESS = 2,
  TOKEN_EXHAUSTED = 3,        // Required Change 6：token 达 [1,2^31-1] 上限
  NO_RETAINED_TRANSACTION = 4, // beginReboundRecovery：prevToken 事务不在保留期
};

/** 结构化返回值（0.6）：失败时 operationToken 恒为 0 */
struct BeginGestureResult {
  int32_t operationToken = 0;
  bool success = false;
  FailureReason failureReason = FailureReason::NONE;
};

/** 不透明纹理句柄（定义于 geometry/curl_geometry.h，避免 GLES 依赖） */

/** 纹理事务状态（0.12） */
enum class TransactionState : int32_t {
  ACTIVE = 0,           // 手势进行中（B1 前）
  PENDING_COMMIT = 1,   // B1 后保留期（默认 900ms，供合成回弹复用）
  RELEASED = 2,         // 已显式释放 / 超时清理
};

/** 纹理事务（0.12/0.13）：以 operationToken 为 key 登记 front/bottom 纹理 */
struct TextureTransaction {
  int32_t key = 0;                    // operationToken
  TextureHandle frontTex = 0;         // front 纹理句柄（不透明整数）
  TextureHandle backTex = 0;          // bottom 纹理句柄
  int32_t frontW = 0;
  int32_t frontH = 0;
  int32_t backW = 0;
  int32_t backH = 0;
  int32_t direction = 1;              // beginGesture 锁定
  int32_t pageGenerationSnapshot = 0; // ArkTS 传入副本（诊断；校验以 ArkTS 为准）
  int64_t retentionDeadlineMs = 0;    // B1 完成 + 900ms（单调时钟 ms）
  TransactionState state = TransactionState::ACTIVE;
};

/** 提交屏障阶段（0.11，诊断/互斥 guard） */
enum class CommitPhase : int32_t {
  B0 = 0,   // 终帧渲染
  B1 = 1,   // GL 已清屏
  B2 = 2,   // 分页已提交（ArkTS 侧）
  B3 = 3,   // Canvas 已刷新
  DONE = 4,
};

/**
 * FlipOperationContext — 一次翻页操作的唯一上下文（评审 Suggestion 2 采纳）。
 * 统一保存 operation token、recovery token、direction、纹理事务、
 * pendingResult 与提交阶段，减少 ArkTS/Native 各自维护字段的语义漂移。
 */
struct FlipOperationContext {
  int32_t operationToken = 0;         // native 生成，∈[1, 2^31-1]
  int32_t recoveryToken = 0;          // beginReboundRecovery 新 token（补救路径非空）
  int32_t direction = 1;              // beginGesture 锁定，生命周期内不可变
  SpineSide spine = SpineSide::LEFT;
  CurlModel model = CurlModel::CYLINDER;
  int32_t pageGenerationSnapshot = 0; // ArkTS 快照副本（诊断）
  bool synthetic = false;             // 合成手势（点击翻页）
  TextureTransaction transaction;     // 本操作的纹理事务
  FlipResult pendingResult = FlipResult::REBOUND;
  CommitPhase commitPhase = CommitPhase::B0;
};

/** 每帧渲染数据（engine 的 render 回调输入，host-compilable） */
struct FrameRenderData {
  float downX = 0.0f;
  float downY = 0.0f;
  float touchX = 0.0f;
  float touchY = 0.0f;
  float radius = 120.0f;
  int32_t direction = 1;
  SpineSide spine = SpineSide::LEFT;
  CurlModel model = CurlModel::CYLINDER;
  float settleT = -1.0f;    // <0 表示拖拽跟手帧；[0,1] 表示收尾插值帧
  bool terminal = false;    // true = 终帧（B0，t>=1）
};

/**
 * FlipStateMachine — 显式状态机（唯一权威）。
 *
 * 线程模型：
 *  - UI 线程：BeginGesture/UpdateGesture/EndGesture/CancelGesture/
 *    BeginReboundRecovery/ReleaseTextureTransaction/SetSurfaceSize；
 *  - soloist 线程：OnFrame(timestampMs)（每帧推进收尾插值 + 900ms 超时判定）；
 *  - 内部 mutex 保护全部可变状态。
 *
 * 完成回调（B1 完成后）：completionCallback(token, result)，经 engine 的
 * 常驻 TSFN 转发 ArkTS；迟到/不匹配 token 的回调由 ArkTS 侧双向校验丢弃。
 */
class FlipStateMachine {
public:
  using RenderCallback = std::function<void(const FrameRenderData&)>;
  using ClearCallback = std::function<void()>;   // B1 清屏（engine 实现 GL）
  using CompletionCallback = std::function<void(int32_t token, FlipResult result)>;

  FlipStateMachine();
  ~FlipStateMachine() = default;

  // ── 注入（engine 在 OnSurfaceCreated 后设置） ───────────────────────
  void SetCallbacks(RenderCallback renderCb, ClearCallback clearCb,
                    CompletionCallback completionCb);
  void SetTsfnAvailable(bool available);
  void SetSurfaceSize(int w, int h);
  void SetDisplayRefreshRate(int rate);
  void SetConfig(const SpringDamperConfig& cfg);

  // ── 意图级 API（0.10/0.13） ────────────────────────────────────────
  BeginGestureResult BeginGesture(int32_t direction, SpineSide spine,
                                  float downX, float downY, CurlModel model,
                                  bool synthetic, int32_t pageGenerationSnapshot,
                                  TextureHandle frontTex, TextureHandle backTex,
                                  int32_t frontW, int32_t frontH,
                                  int32_t backW, int32_t backH);
  void UpdateGesture(int32_t token, float x, float y, int64_t timestampMs);
  bool EndGesture(int32_t token, float x, float y);
  bool CancelGesture(int32_t token);
  BeginGestureResult BeginReboundRecovery(int32_t prevToken, int32_t direction);
  bool ReleaseTextureTransaction(int32_t token);

  // ── 帧驱动（soloist 线程，每帧调用） ───────────────────────────────
  void OnFrame(int64_t timestampMs);

  // ── 查询 ───────────────────────────────────────────────────────────
  FlipState GetState() const;
  int32_t GetActiveToken() const;
  int32_t GetPendingResult() const;
  bool HasPendingCommit() const;              // B1→B3 窗口（禁新手势 guard）
  const TextureTransaction* FindTransaction(int32_t token) const;
  int32_t GetRecoveryTokenFor(int32_t prevToken) const;

  // ── Required Change 5：Surface 销毁清理矩阵 ───────────────────────
  void OnSurfaceDestroyed();

  // ── 测试钩子（host 离线单测用，非线上路径） ───────────────────────
  void SetNextTokenForTest(int32_t next);
  void SetNowForTest(int64_t nowMs);           // 注入单调时钟（测试）

private:
  int32_t AllocateToken();
  void SweepExpiredTransactions(int64_t nowMs);
  void BeginSettling(int64_t nowMs, FlipResult result);
  void AdvanceSettling(int64_t nowMs);
  void ExecuteB1(int64_t nowMs, bool isRecovery);
  void ForceB1OnTimeout(int64_t nowMs);
  void ResetToIdle(int64_t nowMs);
  int64_t NowMs() const;
  bool IsTokenActive(int32_t token) const;
  bool IsCommitWindowOpen() const;             // 有未释放的 PendingCommit 事务

  // ── 状态 ───────────────────────────────────────────────────────────
  mutable std::mutex mutex_;
  FlipState state_ = FlipState::IDLE;
  FlipOperationContext ctx_;
  int32_t activeToken_ = 0;
  int32_t nextToken_ = 1;
  bool tsfnAvailable_ = false;
  int surfaceW_ = 0;
  int surfaceH_ = 0;
  int displayRefreshRate_ = 60;
  SpringDamperConfig cfg_;
  bool configSet_ = false;

  // 纹理事务注册表（key = operationToken）
  std::map<int32_t, TextureTransaction> transactions_;
  // prevToken → recoveryToken 关联（Required Change 3）
  std::map<int32_t, int32_t> recoveryLinks_;

  // 手感状态（UI 线程写 / soloist 线程读，mutex 保护）
  LowPassFilter filter_;
  bool filterInitialized_ = false;
  float targetRadius_ = 120.0f;
  float radius_ = 120.0f;
  float touchX_ = 0.0f;
  float touchY_ = 0.0f;
  float downX_ = 0.0f;
  float downY_ = 0.0f;
  VelocityEstimator velocity_;

  // 收尾插值状态
  int64_t settleStartMs_ = 0;
  int64_t settleDurationMs_ = 300;
  float settleFromX_ = 0.0f;
  float settleFromY_ = 0.0f;
  float settleToX_ = 0.0f;
  float settleToY_ = 0.0f;

  // 注入回调
  RenderCallback renderCb_;
  ClearCallback clearCb_;
  CompletionCallback completionCb_;

  // 测试时钟覆盖（<0 表示使用真实单调时钟）
  int64_t testNowMs_ = -1;
};

}  // namespace flipgl
