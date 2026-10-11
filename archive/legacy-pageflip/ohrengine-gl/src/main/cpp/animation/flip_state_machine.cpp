/*
 * flip_state_machine.cpp — 翻页显式状态机实现（0.10 完整状态转移表）
 *
 * 设计要点：
 *  - 互斥约束：同一时刻仅一个活跃 operationToken；非 Idle 状态拒绝新
 *    beginGesture（OPERATION_IN_PROGRESS）；ReboundRecovery 仅从 Idle 触发。
 *  - operationToken：进程内单调递增 [1, 2^31-1]，0=无效；达上限停止签发。
 *  - 纹理事务：beginGesture 成功时以 token 为 key 登记 front/bottom 纹理；
 *    B1 后转入 PendingCommit 保留期（默认 900ms）；releaseTextureTransaction
 *    显式释放；超时自动清理。
 *  - 900ms 兜底超时：Settling 状态进入后 900ms 内未推进到 t>=1 → 强制 B1 +
 *    pendingResult 降级为 rebound（绝不默认当作完成）。
 *  - Required Change 1：B1 后、ArkTS 完成 B2/B3（releaseTextureTransaction）
 *    之前，beginGesture 一律 OPERATION_IN_PROGRESS（提交屏障 guard）。
 *  - Required Change 5：OnSurfaceDestroyed 清理矩阵（任意状态下的当前操作/
 *    事务/时钟）。
 *
 * 线程模型：UI 线程调用意图级 API；soloist 线程调用 OnFrame；内部 mutex 保护。
 * 本文件禁止包含任何 GL/EGL/OHOS 头文件（host-compilable）。
 */
#include "flip_state_machine.h"

#include <algorithm>
#include <ctime>
#include <cmath>

namespace flipgl {

namespace {
constexpr int64_t kRetentionMs = 900;        // 纹理事务保留期（0.12，默认 900ms）
constexpr int32_t kMaxToken = 0x7FFFFFFF;    // 2^31-1（Required Change 6）
constexpr int64_t kSettleTimeoutMs = 900;    // 收尾超时兜底（0.10）
}  // namespace

FlipStateMachine::FlipStateMachine() = default;

// ── 注入 ────────────────────────────────────────────────────────────────

void FlipStateMachine::SetCallbacks(RenderCallback renderCb, ClearCallback clearCb,
                                    CompletionCallback completionCb) {
  std::lock_guard<std::mutex> lock(mutex_);
  renderCb_ = std::move(renderCb);
  clearCb_ = std::move(clearCb);
  completionCb_ = std::move(completionCb);
}

void FlipStateMachine::SetTsfnAvailable(bool available) {
  std::lock_guard<std::mutex> lock(mutex_);
  tsfnAvailable_ = available;
}

void FlipStateMachine::SetSurfaceSize(int w, int h) {
  std::lock_guard<std::mutex> lock(mutex_);
  surfaceW_ = w;
  surfaceH_ = h;
}

void FlipStateMachine::SetDisplayRefreshRate(int rate) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (rate >= 30 && rate <= 240) {
    displayRefreshRate_ = rate;
  }
}

void FlipStateMachine::SetConfig(const SpringDamperConfig& cfg) {
  std::lock_guard<std::mutex> lock(mutex_);
  cfg_ = cfg;
  configSet_ = true;
  velocity_ = VelocityEstimator(cfg_.velocityRingSize > 0 ? cfg_.velocityRingSize : 8);
}

// ── token 生成与校验（0.13 / Required Change 6） ──────────────────────

int32_t FlipStateMachine::AllocateToken() {
  if (nextToken_ >= kMaxToken) {
    return 0;  // 达上限，拒绝签发（TOKEN_EXHAUSTED）
  }
  return nextToken_++;
}

bool FlipStateMachine::IsTokenActive(int32_t token) const {
  return activeToken_ != 0 && token == activeToken_;
}

int64_t FlipStateMachine::NowMs() const {
  if (testNowMs_ >= 0) {
    return testNowMs_;
  }
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

// ── 纹理事务（0.12/0.13） ─────────────────────────────────────────────

const TextureTransaction* FlipStateMachine::FindTransaction(int32_t token) const {
  auto it = transactions_.find(token);
  if (it == transactions_.end()) {
    return nullptr;
  }
  return &it->second;
}

int32_t FlipStateMachine::GetRecoveryTokenFor(int32_t prevToken) const {
  auto it = recoveryLinks_.find(prevToken);
  if (it == recoveryLinks_.end()) {
    return 0;
  }
  return it->second;
}

bool FlipStateMachine::IsCommitWindowOpen() const {
  for (const auto& kv : transactions_) {
    if (kv.second.state == TransactionState::PENDING_COMMIT) {
      return true;
    }
  }
  return false;
}

void FlipStateMachine::SweepExpiredTransactions(int64_t nowMs) {
  for (auto it = transactions_.begin(); it != transactions_.end();) {
    if (it->second.state == TransactionState::PENDING_COMMIT &&
        it->second.retentionDeadlineMs > 0 && nowMs > it->second.retentionDeadlineMs) {
      // 保留期过期自动清理（显存泄漏防护，0.12）
      it = transactions_.erase(it);
    } else {
      ++it;
    }
  }
}

// ── 意图级 API（0.10 状态转移表） ─────────────────────────────────────

BeginGestureResult FlipStateMachine::BeginGesture(
    int32_t direction, SpineSide spine, float downX, float downY, CurlModel model,
    bool synthetic, int32_t pageGenerationSnapshot,
    TextureHandle frontTex, TextureHandle backTex,
    int32_t frontW, int32_t frontH, int32_t backW, int32_t backH) {
  std::lock_guard<std::mutex> lock(mutex_);
  const int64_t now = NowMs();
  SweepExpiredTransactions(now);

  // 互斥约束 + 提交屏障 guard（Required Change 1）：B1→B3 窗口禁新手势
  if (state_ != FlipState::IDLE || activeToken_ != 0 || IsCommitWindowOpen()) {
    BeginGestureResult r;
    r.success = false;
    r.failureReason = FailureReason::OPERATION_IN_PROGRESS;
    return r;
  }
  if (!tsfnAvailable_) {
    BeginGestureResult r;
    r.success = false;
    r.failureReason = FailureReason::TSFN_UNAVAILABLE;
    return r;
  }
  const int32_t token = AllocateToken();
  if (token == 0) {
    BeginGestureResult r;
    r.success = false;
    r.failureReason = FailureReason::TOKEN_EXHAUSTED;
    return r;
  }

  // 登记纹理事务（0.12：beginGesture 成功即登记 front/bottom 纹理）
  TextureTransaction tx;
  tx.key = token;
  tx.frontTex = frontTex;
  tx.backTex = backTex;
  tx.frontW = frontW;
  tx.frontH = frontH;
  tx.backW = backW;
  tx.backH = backH;
  tx.direction = direction;
  tx.pageGenerationSnapshot = pageGenerationSnapshot;
  tx.state = TransactionState::ACTIVE;
  transactions_[token] = tx;

  // 初始化操作上下文
  ctx_ = FlipOperationContext();
  ctx_.operationToken = token;
  ctx_.direction = direction;
  ctx_.spine = spine;
  ctx_.model = model;
  ctx_.pageGenerationSnapshot = pageGenerationSnapshot;
  ctx_.synthetic = synthetic;
  ctx_.transaction = tx;
  ctx_.pendingResult = FlipResult::REBOUND;
  ctx_.commitPhase = CommitPhase::B0;

  activeToken_ = token;
  state_ = FlipState::DRAGGING;

  // 重置手感状态（滤波基线、速度缓冲、半径）
  downX_ = downX;
  downY_ = downY;
  touchX_ = downX;
  touchY_ = downY;
  filter_.Reset();
  filterInitialized_ = false;
  velocity_.Reset();
  targetRadius_ = ComputeRadiusTarget(0.0f, static_cast<float>(surfaceW_), cfg_);
  radius_ = targetRadius_;
  settleStartMs_ = 0;

  BeginGestureResult r;
  r.operationToken = token;
  r.success = true;
  r.failureReason = FailureReason::NONE;
  return r;
}

void FlipStateMachine::UpdateGesture(int32_t token, float x, float y, int64_t timestampMs) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!IsTokenActive(token)) {
    return;  // token 不匹配 → 丢弃（迟到/错位更新，0.13 双向校验）
  }
  if (state_ != FlipState::DRAGGING) {
    return;
  }
  // 位置-时间样本（速度估算环形缓冲）
  velocity_.AddSample(x, y, timestampMs);
  // 低通滤波（跟手平滑，参数来自 spring_damper 配置，0.6/0.7）
  if (!filterInitialized_) {
    filter_.Update(x, y, 1.0f);
    filterInitialized_ = true;
  } else {
    filter_.Update(x, y, cfg_.filterLerp);
  }
  touchX_ = filter_.X();
  touchY_ = filter_.Y();
  // 半径目标值随拖拽距离更新（spring_damper 手感配置，0.4）
  const float dx = touchX_ - downX_;
  const float dy = touchY_ - downY_;
  const float dragLen = std::sqrt(dx * dx + dy * dy);
  targetRadius_ = ComputeRadiusTarget(dragLen, static_cast<float>(surfaceW_), cfg_);
}

bool FlipStateMachine::EndGesture(int32_t token, float x, float y) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!IsTokenActive(token) || state_ != FlipState::DRAGGING) {
    return false;
  }
  const int64_t now = NowMs();

  // 末速度估算（0.6：速度唯一归属 native；px/ms）
  float vx = 0.0f, vy = 0.0f;
  velocity_.Estimate(vx, vy);

  // 完成/回弹阈值判定（0.6/0.14；替换 ArkTS releaseCurl 的 fx vs midX 判定）
  //  forwardSign：spine=right 时 1，否则 -1（与现 ArkTS releaseCurl 一致）
  const float forwardSign = ctx_.spine == SpineSide::RIGHT ? 1.0f : -1.0f;
  const float dirSign = static_cast<float>(ctx_.direction);
  const float horizontalTravel = std::fabs(x - downX_);
  const float verticalTravel = std::fabs(y - downY_);
  const float midX = static_cast<float>(surfaceW_) * cfg_.completeThresholdFraction;
  // 横向位移主导判定（原 hasHorizontalCommit：>= max(30vp, |dy|*0.15)）
  const float minCommit = std::max(cfg_.minHorizontalCommitPx, verticalTravel * cfg_.verticalWeightRatio);
  const bool hasHorizontalCommit = horizontalTravel >= minCommit;
  const bool pastMid = forwardSign * dirSign * (x - midX) > 0.0f;
  // 末速度辅助判定：方向与完成方向一致且超过阈值 → 视为越过
  const bool velAssist = forwardSign * dirSign * vx > cfg_.velocityAssistThreshold;
  const bool completed = hasHorizontalCommit && (pastMid || velAssist);

  ctx_.pendingResult = completed ? FlipResult::COMPLETED : FlipResult::REBOUND;

  // 收尾插值区间（临界阻尼弹簧，0.8/0.10）：
  //  - completed：起点=当前触摸，终点=释放点 + 惯性预估（clamp 到 surface）
  //  - rebound：终点 = 按下点（收回原位）
  settleFromX_ = touchX_;
  settleFromY_ = touchY_;
  if (completed) {
    const float sw = static_cast<float>(surfaceW_);
    const float sh = static_cast<float>(surfaceH_);
    settleToX_ = std::max(0.0f, std::min(sw, x + vx * cfg_.inertiaTimeMs));
    settleToY_ = std::max(0.0f, std::min(sh, y + vy * cfg_.inertiaTimeMs));
  } else {
    settleToX_ = downX_;
    settleToY_ = downY_;
  }
  // 收尾时长：随距离线性（原 ArkTS selectAnimationDuration 220+ratio*220 语义）
  const float distX = std::fabs(settleToX_ - settleFromX_);
  const float distY = std::fabs(settleToY_ - settleFromY_);
  const float dist = std::sqrt(distX * distX + distY * distY);
  const float sw = std::max(1.0f, static_cast<float>(surfaceW_));
  const float ratio = std::min(1.0f, dist / sw);
  settleDurationMs_ = cfg_.settleMinMs + ratio * cfg_.settleRangeMs;

  settleStartMs_ = now;
  state_ = completed ? FlipState::SETTLING_TO_COMPLETE : FlipState::SETTLING_TO_REBOUND;
  ctx_.commitPhase = CommitPhase::B0;
  return true;
}

bool FlipStateMachine::CancelGesture(int32_t token) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!IsTokenActive(token)) {
    return false;
  }
  const int64_t now = NowMs();
  // 0.10：cancelGesture → 立即 B1 清屏 → Cancelling → Idle
  state_ = FlipState::CANCELLING;
  ctx_.commitPhase = CommitPhase::B1;
  if (clearCb_) {
    clearCb_();
  }
  // 取消路径不登记纹理事务（无需回弹补救，0.10）；释放已登记的当前事务
  transactions_.erase(token);
  ResetToIdle(now);
  return true;
}

BeginGestureResult FlipStateMachine::BeginReboundRecovery(int32_t prevToken, int32_t direction) {
  std::lock_guard<std::mutex> lock(mutex_);
  const int64_t now = NowMs();
  SweepExpiredTransactions(now);

  BeginGestureResult r;
  // guard：仅 Idle 且无活跃 token；prevToken 事务须在保留期内且未释放（0.12）
  if (state_ != FlipState::IDLE || activeToken_ != 0) {
    r.failureReason = FailureReason::OPERATION_IN_PROGRESS;
    return r;
  }
  auto it = transactions_.find(prevToken);
  if (it == transactions_.end() ||
      it->second.state != TransactionState::PENDING_COMMIT) {
    r.failureReason = FailureReason::NO_RETAINED_TRANSACTION;
    return r;
  }
  if (!tsfnAvailable_) {
    r.failureReason = FailureReason::TSFN_UNAVAILABLE;
    return r;
  }
  const int32_t newToken = AllocateToken();
  if (newToken == 0) {
    r.failureReason = FailureReason::TOKEN_EXHAUSTED;
    return r;
  }

  // 复用原事务（不重新截图/上传），事务重新关联到新 token（Required Change 3）
  TextureTransaction tx = it->second;
  tx.key = newToken;
  tx.state = TransactionState::ACTIVE;
  transactions_[newToken] = tx;
  transactions_.erase(prevToken);
  recoveryLinks_[prevToken] = newToken;

  // 回弹起点 = 原收尾目标（目标页完成态），终点 = 按下点（原始页态，0.12）
  ctx_ = FlipOperationContext();
  ctx_.operationToken = newToken;
  ctx_.recoveryToken = newToken;
  ctx_.direction = direction;
  ctx_.spine = tx.direction > 0 ? SpineSide::LEFT : SpineSide::RIGHT;  // 诊断用（事务仅存 direction）
  ctx_.model = CurlModel::CYLINDER;
  ctx_.pageGenerationSnapshot = tx.pageGenerationSnapshot;
  ctx_.transaction = tx;
  ctx_.pendingResult = FlipResult::REBOUND;
  ctx_.commitPhase = CommitPhase::B0;

  activeToken_ = newToken;
  state_ = FlipState::REBOUND_RECOVERY;
  downX_ = ctx_.direction > 0 ? 0.0f : static_cast<float>(surfaceW_);
  downY_ = 0.0f;
  settleFromX_ = settleToX_;
  settleFromY_ = settleToY_;
  settleToX_ = downX_;
  settleToY_ = downY_;
  settleDurationMs_ = cfg_.settleMinMs;
  settleStartMs_ = now;

  r.operationToken = newToken;
  r.success = true;
  return r;
}

bool FlipStateMachine::ReleaseTextureTransaction(int32_t token) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = transactions_.find(token);
  if (it == transactions_.end()) {
    return false;
  }
  it->second.state = TransactionState::RELEASED;
  transactions_.erase(it);
  // 清理 recovery 关联（反向）
  for (auto rit = recoveryLinks_.begin(); rit != recoveryLinks_.end();) {
    if (rit->second == token) {
      rit = recoveryLinks_.erase(rit);
    } else {
      ++rit;
    }
  }
  return true;
}

// ── 帧驱动（soloist 线程） ─────────────────────────────────────────────

void FlipStateMachine::OnFrame(int64_t timestampMs) {
  std::lock_guard<std::mutex> lock(mutex_);
  const int64_t now = timestampMs > 0 ? timestampMs : NowMs();
  switch (state_) {
    case FlipState::DRAGGING: {
      // 拖拽跟手帧：半径阻尼弹簧软收敛 + 渲染
      radius_ += (targetRadius_ - radius_) * cfg_.radiusSpringK;
      FrameRenderData d = {};
      d.downX = downX_;
      d.downY = downY_;
      d.touchX = touchX_;
      d.touchY = touchY_;
      d.radius = radius_;
      d.direction = ctx_.direction;
      d.spine = ctx_.spine;
      d.model = ctx_.model;
      d.settleT = -1.0f;
      if (renderCb_) {
        renderCb_(d);
      }
      break;
    }
    case FlipState::SETTLING_TO_COMPLETE:
    case FlipState::SETTLING_TO_REBOUND: {
      // 900ms 兜底超时（0.10）：进入 Settling 后 900ms 内未推进到 t>=1
      if (settleStartMs_ > 0 && (now - settleStartMs_) > kSettleTimeoutMs) {
        ForceB1OnTimeout(now);
        break;
      }
      AdvanceSettling(now);
      break;
    }
    case FlipState::REBOUND_RECOVERY: {
      if (settleStartMs_ > 0 && (now - settleStartMs_) > kSettleTimeoutMs) {
        ForceB1OnTimeout(now);
        break;
      }
      AdvanceSettling(now);
      break;
    }
    default:
      break;
  }
}

void FlipStateMachine::BeginSettling(int64_t nowMs, FlipResult result) {
  ctx_.pendingResult = result;
  settleStartMs_ = nowMs;
  state_ = (result == FlipResult::COMPLETED)
      ? FlipState::SETTLING_TO_COMPLETE
      : FlipState::SETTLING_TO_REBOUND;
}

void FlipStateMachine::AdvanceSettling(int64_t nowMs) {
  const bool isRecovery = state_ == FlipState::REBOUND_RECOVERY;
  int64_t elapsed = nowMs - settleStartMs_;
  if (elapsed < 0) {
    elapsed = 0;
  }
  const float t = settleDurationMs_ > 0
      ? static_cast<float>(elapsed) / static_cast<float>(settleDurationMs_)
      : 1.0f;
  const float clampedT = std::min(1.0f, std::max(0.0f, t));
  const float e = CriticalDampingCurve(clampedT, cfg_.criticalDampingK);
  touchX_ = settleFromX_ + (settleToX_ - settleFromX_) * e;
  touchY_ = settleFromY_ + (settleToY_ - settleFromY_) * e;

  const float dx = touchX_ - downX_;
  const float dy = touchY_ - downY_;
  const float dragLen = std::sqrt(dx * dx + dy * dy);
  targetRadius_ = ComputeRadiusTarget(dragLen, static_cast<float>(surfaceW_), cfg_);
  radius_ += (targetRadius_ - radius_) * cfg_.radiusSpringK;

  const bool terminal = clampedT >= 1.0f;
  FrameRenderData d = {};
  d.downX = downX_;
  d.downY = downY_;
  d.touchX = touchX_;
  d.touchY = touchY_;
  d.radius = radius_;
  d.direction = ctx_.direction;
  d.spine = ctx_.spine;
  d.model = ctx_.model;
  d.settleT = clampedT;
  d.terminal = terminal;
  if (renderCb_) {
    renderCb_(d);  // B0：终帧渲染（t>=1 时 terminal=true）
  }
  if (terminal) {
    // B1：终帧渲染完成后清屏，事务转保留期，触发完成回调（0.10/0.11）
    ExecuteB1(nowMs, isRecovery);
  }
}

void FlipStateMachine::ExecuteB1(int64_t nowMs, bool isRecovery) {
  // B1：GL 已清屏（0.11，B1 完成前不触发任何完成回调）
  if (clearCb_) {
    clearCb_();
  }
  // 纹理事务转入 pending-commit 保留期（0.12，默认 900ms）
  auto it = transactions_.find(ctx_.operationToken);
  if (it != transactions_.end()) {
    it->second.state = TransactionState::PENDING_COMMIT;
    it->second.retentionDeadlineMs = nowMs + kRetentionMs;
  }
  ctx_.commitPhase = CommitPhase::B1;

  // 完成回调（携带 token 与最终结果）
  if (completionCb_) {
    completionCb_(ctx_.operationToken, ctx_.pendingResult);
  }
  // ReboundRecovery 完成：释放纹理事务（0.12，不再复用）
  if (isRecovery) {
    transactions_.erase(ctx_.operationToken);
  }
  ResetToIdle(nowMs);
}

void FlipStateMachine::ForceB1OnTimeout(int64_t nowMs) {
  // 900ms 超时语义（0.10/0.12）：强制 B1 + pendingResult 降级为 rebound
  ctx_.pendingResult = FlipResult::REBOUND;
  ExecuteB1(nowMs, state_ == FlipState::REBOUND_RECOVERY);
}

void FlipStateMachine::ResetToIdle(int64_t nowMs) {
  (void)nowMs;
  activeToken_ = 0;
  state_ = FlipState::IDLE;
  settleStartMs_ = 0;
}

// ── Required Change 5：Surface 销毁清理矩阵 ────────────────────────────

void FlipStateMachine::OnSurfaceDestroyed() {
  std::lock_guard<std::mutex> lock(mutex_);
  // 任意状态（Dragging/Settling/pending-commit）下清理：
  //  - 当前操作 → 作废（token 失效、状态回 Idle）
  //  - 纹理事务 → 全部释放
  //  - 定时器/收尾插值 → 复位
  transactions_.clear();
  recoveryLinks_.clear();
  ctx_ = FlipOperationContext();
  activeToken_ = 0;
  state_ = FlipState::IDLE;
  settleStartMs_ = 0;
  filterInitialized_ = false;
  tsfnAvailable_ = false;
}

// ── 查询 ───────────────────────────────────────────────────────────────

FlipState FlipStateMachine::GetState() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return state_;
}

int32_t FlipStateMachine::GetActiveToken() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return activeToken_;
}

int32_t FlipStateMachine::GetPendingResult() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return static_cast<int32_t>(ctx_.pendingResult);
}

bool FlipStateMachine::HasPendingCommit() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return IsCommitWindowOpen();
}

// ── 测试钩子 ───────────────────────────────────────────────────────────

void FlipStateMachine::SetNextTokenForTest(int32_t next) {
  std::lock_guard<std::mutex> lock(mutex_);
  nextToken_ = next;
}

void FlipStateMachine::SetNowForTest(int64_t nowMs) {
  std::lock_guard<std::mutex> lock(mutex_);
  testNowMs_ = nowMs;
}

}  // namespace flipgl
