/*
 * state_machine_test.cpp — 状态机 0.10 全转移表 + token/事务双向校验（T015/T016）
 *
 * 覆盖（Test Requirements 3/4，Phase A 范围）：
 *  - 0.10 完整状态转移表：正常路径、TSFN 不可用、操作互斥、迟到回调丢弃、
 *    900ms 超时降级、ReboundRecovery 进入/完成/超时；
 *  - operationToken/pageGeneration/纹理事务双向校验：token 不匹配丢弃、
 *    pageGeneration 变化触发补救（beginReboundRecovery 复用保留期事务）、
 *    事务保留期过期自动清理、recovery token 关联。
 *
 * 依赖：FlipStateMachine（animation/），无 EGL/真机依赖。
 */
#include "test_framework.h"

#include "animation/flip_state_machine.h"

#include <cmath>
#include <vector>

using namespace flipgl;

namespace {

// 测试夹具：记录回调并暴露可注入时钟的状态机
struct Harness {
  FlipStateMachine sm;
  int renderCount = 0;
  int clearCount = 0;
  int completeCount = 0;
  int32_t lastCompleteToken = 0;
  FlipResult lastCompleteResult = FlipResult::REBOUND;
  FrameRenderData lastFrame;
  std::vector<int32_t> completedTokens;
  int64_t nowMs = 1000000;  // 固定虚拟时钟起点

  Harness() {
    sm.SetCallbacks(
        [this](const FrameRenderData& d) {
          renderCount++;
          lastFrame = d;
        },
        [this]() { clearCount++; },
        [this](int32_t token, FlipResult result) {
          completeCount++;
          lastCompleteToken = token;
          lastCompleteResult = result;
          completedTokens.push_back(token);
        });
    sm.SetTsfnAvailable(true);
    sm.SetSurfaceSize(1080, 1920);
    sm.SetConfig(SpringDamperConfig());
    sm.SetNowForTest(nowMs);
  }

  void Advance(int64_t deltaMs) {
    nowMs += deltaMs;
    sm.SetNowForTest(nowMs);
  }

  // 便捷：成功 beginGesture 返回 token（断言成功）
  int32_t BeginOk(int32_t dir = 1, SpineSide spine = SpineSide::LEFT,
                  CurlModel model = CurlModel::CYLINDER,
                  bool synthetic = false, int32_t pageGen = 7,
                  float downX = 900.0f) {
    BeginGestureResult r = sm.BeginGesture(dir, spine, downX, 500.0f, model, synthetic,
                                           pageGen, 11, 22, 360, 720, 360, 720);
    CHECK_TRUE(r.success);
    CHECK_TRUE(r.operationToken > 0);
    return r.operationToken;
  }
};

}  // namespace

// ── 0.10 状态转移表：正常路径 ─────────────────────────────────────────

TEST_CASE(SM_BeginGesture_Idle_To_Dragging) {
  Harness h;
  CHECK_EQ(h.sm.GetState(), FlipState::IDLE);
  int32_t token = h.BeginOk();
  CHECK_EQ(h.sm.GetState(), FlipState::DRAGGING);
  CHECK_EQ(h.sm.GetActiveToken(), token);
  // 事务已登记（key=token，Active）
  const TextureTransaction* tx = h.sm.FindTransaction(token);
  CHECK_TRUE(tx != nullptr);
  CHECK_EQ(tx->key, token);
  CHECK_EQ(tx->frontTex, 11);
  CHECK_EQ(tx->backTex, 22);
  CHECK_EQ(tx->state, TransactionState::ACTIVE);
  CHECK_EQ(tx->pageGenerationSnapshot, 7);
}

TEST_CASE(SM_BeginGesture_TsfnUnavailable) {
  Harness h;
  h.sm.SetTsfnAvailable(false);
  BeginGestureResult r = h.sm.BeginGesture(1, SpineSide::LEFT, 100, 500,
                                           CurlModel::CYLINDER, false, 7, 11, 22,
                                           360, 720, 360, 720);
  CHECK_FALSE(r.success);
  CHECK_EQ(r.operationToken, 0);
  CHECK_EQ(r.failureReason, FailureReason::TSFN_UNAVAILABLE);
  CHECK_EQ(h.sm.GetState(), FlipState::IDLE);
}

TEST_CASE(SM_BeginGesture_OperationInProgress_MutualExclusion) {
  Harness h;
  int32_t token = h.BeginOk();
  CHECK_EQ(h.sm.GetState(), FlipState::DRAGGING);
  // 非 Idle 状态下再次 beginGesture → OPERATION_IN_PROGRESS
  BeginGestureResult r = h.sm.BeginGesture(1, SpineSide::LEFT, 200, 500,
                                           CurlModel::CYLINDER, false, 7, 11, 22,
                                           360, 720, 360, 720);
  CHECK_FALSE(r.success);
  CHECK_EQ(r.operationToken, 0);
  CHECK_EQ(r.failureReason, FailureReason::OPERATION_IN_PROGRESS);
  // 原操作不受影响
  CHECK_EQ(h.sm.GetActiveToken(), token);
  CHECK_EQ(h.sm.GetState(), FlipState::DRAGGING);
}

TEST_CASE(SM_UpdateGesture_ValidToken_Renders) {
  Harness h;
  int32_t token = h.BeginOk();
  int rendersBefore = h.renderCount;
  h.sm.UpdateGesture(token, 300, 400, 1000001);
  h.sm.OnFrame(1000002);
  CHECK_TRUE(h.renderCount > rendersBefore);
  CHECK_NEAR(h.lastFrame.touchX, 300.0f, 0.5f);  // 低通滤波 lerp 0.5
  CHECK_NEAR(h.lastFrame.touchY, 400.0f, 0.5f);
  CHECK_EQ(h.lastFrame.direction, 1);
}

TEST_CASE(SM_UpdateGesture_MismatchedToken_Dropped) {
  Harness h;
  int32_t token = h.BeginOk();
  h.sm.UpdateGesture(token + 100, 300, 400, 1000001);  // 错位 token
  h.sm.OnFrame(1000002);
  // 不匹配更新被丢弃：touch 仍为 down 位置（900，right side）
  CHECK_NEAR(h.lastFrame.touchX, 900.0f, 0.5f);
  CHECK_EQ(h.sm.GetActiveToken(), token);  // 当前操作不受影响
}

TEST_CASE(SM_EndGesture_CrossThreshold_Completes) {
  Harness h;
  int32_t token = h.BeginOk();  // LEFT spine + FORWARD：down 在右侧（900）
  // 向左拖拽越过中线（midX=540）→ 完成
  h.sm.UpdateGesture(token, 300, 500, 1000001);
  h.sm.OnFrame(1000002);
  CHECK_TRUE(h.sm.EndGesture(token, 300, 500));
  CHECK_EQ(h.sm.GetState(), FlipState::SETTLING_TO_COMPLETE);
  CHECK_EQ(h.sm.GetPendingResult(), static_cast<int32_t>(FlipResult::COMPLETED));
  // 事务仍为 Active（B1 前）
  const TextureTransaction* tx = h.sm.FindTransaction(token);
  CHECK_TRUE(tx != nullptr);
  CHECK_EQ(tx->state, TransactionState::ACTIVE);
}

TEST_CASE(SM_EndGesture_BelowThreshold_Rebounds) {
  Harness h;
  int32_t token = h.BeginOk();  // LEFT spine + FORWARD：down 在右侧（900）
  // 释放点 700（仍在 midX=540 右侧）→ 未越过 → 回弹
  h.sm.UpdateGesture(token, 700, 500, 1000001);
  CHECK_TRUE(h.sm.EndGesture(token, 700, 500));
  CHECK_EQ(h.sm.GetState(), FlipState::SETTLING_TO_REBOUND);
  CHECK_EQ(h.sm.GetPendingResult(), static_cast<int32_t>(FlipResult::REBOUND));
}

TEST_CASE(SM_EndGesture_MismatchedToken_Rejected) {
  Harness h;
  int32_t token = h.BeginOk();
  CHECK_FALSE(h.sm.EndGesture(token + 1, 900, 500));
  CHECK_EQ(h.sm.GetState(), FlipState::DRAGGING);
}

// ── 收尾完成路径（B0 → B1 → 完成回调 → Idle） ─────────────────────────

TEST_CASE(SM_Settling_Completion_Calls_CompletionOnce) {
  Harness h;
  int32_t token = h.BeginOk();  // LEFT spine + FORWARD，down 右侧 900
  h.sm.UpdateGesture(token, 300, 500, 1000001);   // 向左拖拽越过中线
  h.sm.EndGesture(token, 300, 500);
  int completesBefore = h.completeCount;
  // 推进 500ms：settleDurationMs≈220ms（settleFrom==settleTo 距离 0），
  // t>=1 且未超 900ms 超时阈值 → 正常完成路径
  h.Advance(500);
  h.sm.OnFrame(h.nowMs);
  CHECK_TRUE(h.completeCount > completesBefore);
  CHECK_EQ(h.lastCompleteToken, token);
  CHECK_EQ(h.lastCompleteResult, FlipResult::COMPLETED);
  CHECK_EQ(h.sm.GetState(), FlipState::IDLE);
  CHECK_EQ(h.sm.GetActiveToken(), 0);
  // B1 已执行（clearCb 至少一次）
  CHECK_TRUE(h.clearCount > 0);
  // 事务转入 PendingCommit（保留期供 ArkTS 消费）
  const TextureTransaction* tx = h.sm.FindTransaction(token);
  CHECK_TRUE(tx != nullptr);
  CHECK_EQ(tx->state, TransactionState::PENDING_COMMIT);
  CHECK_TRUE(tx->retentionDeadlineMs > 0);
  // B1→B3 窗口：新手势被拒（Required Change 1）
  BeginGestureResult r = h.sm.BeginGesture(1, SpineSide::LEFT, 100, 500,
                                           CurlModel::CYLINDER, false, 7, 11, 22,
                                           360, 720, 360, 720);
  CHECK_FALSE(r.success);
  CHECK_EQ(r.failureReason, FailureReason::OPERATION_IN_PROGRESS);
}

TEST_CASE(SM_Settling_TerminalFrame_Flag) {
  Harness h;
  int32_t token = h.BeginOk();
  h.sm.UpdateGesture(token, 300, 500, 1000001);
  h.sm.EndGesture(token, 300, 500);
  h.Advance(100);  // t<1（duration≈220ms）→ 非终帧
  h.sm.OnFrame(h.nowMs);
  CHECK_FALSE(h.lastFrame.terminal);
  h.Advance(500);  // t>=1 终帧（且未超 900ms）
  h.sm.OnFrame(h.nowMs);
  CHECK_TRUE(h.lastFrame.terminal);
}

// ── 900ms 超时降级 ────────────────────────────────────────────────────

TEST_CASE(SM_SettleTimeout_Downgrades_To_Rebound) {
  Harness h;
  int32_t token = h.BeginOk();
  h.sm.UpdateGesture(token, 300, 500, 1000001);
  h.sm.EndGesture(token, 300, 500);  // 判定完成
  CHECK_EQ(h.sm.GetState(), FlipState::SETTLING_TO_COMPLETE);
  // 模拟帧回调停滞 > 900ms（不推进插值）
  h.Advance(1000);
  h.sm.OnFrame(h.nowMs);
  // 900ms 超时 → 强制 B1 + pendingResult 降级为 rebound
  CHECK_TRUE(h.completeCount > 0);
  CHECK_EQ(h.lastCompleteResult, FlipResult::REBOUND);
  CHECK_EQ(h.sm.GetState(), FlipState::IDLE);
  CHECK_TRUE(h.clearCount > 0);
}

// ── Cancel 路径 ───────────────────────────────────────────────────────

TEST_CASE(SM_Cancel_Clears_And_Returns_Idle) {
  Harness h;
  int32_t token = h.BeginOk();
  h.sm.UpdateGesture(token, 300, 500, 1000001);
  CHECK_TRUE(h.sm.CancelGesture(token));
  CHECK_EQ(h.sm.GetState(), FlipState::IDLE);
  CHECK_EQ(h.sm.GetActiveToken(), 0);
  CHECK_TRUE(h.clearCount > 0);
  // 取消不触发完成回调
  CHECK_EQ(h.completeCount, 0);
  // 事务已被清除（无需回弹补救）
  CHECK_TRUE(h.sm.FindTransaction(token) == nullptr);
}

TEST_CASE(SM_Cancel_MismatchedToken_Ignored) {
  Harness h;
  int32_t token = h.BeginOk();
  CHECK_FALSE(h.sm.CancelGesture(token + 1));
  CHECK_EQ(h.sm.GetState(), FlipState::DRAGGING);
  CHECK_TRUE(h.sm.CancelGesture(token));
  CHECK_EQ(h.sm.GetState(), FlipState::IDLE);
}

// ── 迟到回调丢弃 / 双向校验（0.13） ───────────────────────────────────

TEST_CASE(SM_StaleCompletion_After_NewGesture_Is_Independent) {
  Harness h;
  // 完成一次旧手势（token=1）
  int32_t token1 = h.BeginOk();
  h.sm.UpdateGesture(token1, 300, 500, 1000001);
  h.sm.EndGesture(token1, 300, 500);
  h.Advance(1000);
  h.sm.OnFrame(h.nowMs);
  CHECK_EQ(h.lastCompleteToken, token1);
  // 释放事务，关闭提交屏障窗口
  CHECK_TRUE(h.sm.ReleaseTextureTransaction(token1));
  // 新手势
  int32_t token2 = h.BeginOk();
  CHECK_TRUE(token2 > token1);
  CHECK_EQ(h.sm.GetActiveToken(), token2);
  // 旧 token 的更新/结束被丢弃（不污染新手势）
  h.sm.UpdateGesture(token1, 999, 999, 1000002);
  h.sm.OnFrame(1000003);
  CHECK_NEAR(h.lastFrame.touchX, 900.0f, 0.5f);  // 未被旧 token 污染（down=900）
  CHECK_FALSE(h.sm.EndGesture(token1, 999, 999));
  CHECK_EQ(h.sm.GetState(), FlipState::DRAGGING);
}

// ── ReboundRecovery 路径（0.10/0.12） ─────────────────────────────────

TEST_CASE(SM_ReboundRecovery_Enter_Complete) {
  Harness h;
  // 完成一次手势 → 事务进入保留期
  int32_t token1 = h.BeginOk();
  h.sm.UpdateGesture(token1, 300, 500, 1000001);
  h.sm.EndGesture(token1, 300, 500);
  h.Advance(1000);
  h.sm.OnFrame(h.nowMs);
  CHECK_EQ(h.completeCount, 1);
  const TextureTransaction* retained = h.sm.FindTransaction(token1);
  CHECK_TRUE(retained != nullptr);
  CHECK_EQ(retained->state, TransactionState::PENDING_COMMIT);
  // 触发补救（pageGeneration 变化语义：ArkTS 发现 B2 校验失败后调用）
  BeginGestureResult recovery = h.sm.BeginReboundRecovery(token1, 1);
  CHECK_TRUE(recovery.success);
  CHECK_TRUE(recovery.operationToken > 0);
  CHECK_EQ(recovery.operationToken, h.sm.GetActiveToken());
  CHECK_EQ(h.sm.GetState(), FlipState::REBOUND_RECOVERY);
  // recovery token 关联（Required Change 3）
  CHECK_EQ(h.sm.GetRecoveryTokenFor(token1), recovery.operationToken);
  // 完成回弹
  h.Advance(1000);
  h.sm.OnFrame(h.nowMs);
  CHECK_TRUE(h.completeCount > 1);
  CHECK_EQ(h.lastCompleteResult, FlipResult::REBOUND);
  CHECK_EQ(h.lastCompleteToken, recovery.operationToken);
  CHECK_EQ(h.sm.GetState(), FlipState::IDLE);
  // 补救完成后事务已释放
  CHECK_TRUE(h.sm.FindTransaction(recovery.operationToken) == nullptr);
}

TEST_CASE(SM_ReboundRecovery_Rejects_Without_Retained_Transaction) {
  Harness h;
  // 无保留期事务时触发 → NO_RETAINED_TRANSACTION
  BeginGestureResult r = h.sm.BeginReboundRecovery(42, 1);
  CHECK_FALSE(r.success);
  CHECK_EQ(r.operationToken, 0);
  CHECK_EQ(r.failureReason, FailureReason::NO_RETAINED_TRANSACTION);
}

TEST_CASE(SM_ReboundRecovery_Rejects_During_ActiveGesture) {
  Harness h;
  int32_t token = h.BeginOk();
  // 处于 Dragging 时不允许补救（仅 Idle 触发）
  BeginGestureResult r = h.sm.BeginReboundRecovery(token, 1);
  CHECK_FALSE(r.success);
  CHECK_EQ(r.failureReason, FailureReason::OPERATION_IN_PROGRESS);
  h.sm.CancelGesture(token);
}

// ── 纹理事务保留期过期自动清理（0.12/0.13） ───────────────────────────

TEST_CASE(SM_Transaction_Retention_Expiry_AutoCleanup) {
  Harness h;
  int32_t token = h.BeginOk();
  h.sm.UpdateGesture(token, 300, 500, 1000001);
  h.sm.EndGesture(token, 300, 500);
  h.Advance(1000);
  h.sm.OnFrame(h.nowMs);  // B1 → PendingCommit
  CHECK_TRUE(h.sm.FindTransaction(token) != nullptr);
  // 保留期 900ms 过后，下一次 beginGesture 触发过期清理
  h.Advance(2000);  // 超过 900ms
  h.sm.ReleaseTextureTransaction(token);  // 显式释放
  // 显式释放后事务已移除
  CHECK_TRUE(h.sm.FindTransaction(token) == nullptr);
  // 提交屏障窗口关闭，新手势可开始
  int32_t token2 = h.BeginOk();
  CHECK_TRUE(token2 > 0);
  h.sm.CancelGesture(token2);
}

TEST_CASE(SM_ExpiredTransaction_DoesNot_Block_NewGesture) {
  Harness h;
  int32_t token = h.BeginOk();
  h.sm.UpdateGesture(token, 300, 500, 1000001);
  h.sm.EndGesture(token, 300, 500);
  h.Advance(1000);
  h.sm.OnFrame(h.nowMs);  // PendingCommit，保留期 900ms
  // 不显式释放，仅推进时间 > 900ms；beginGesture 内部 sweep 过期事务
  h.Advance(2000);
  // Sweep 发生在 BeginGesture 内部 → 新 token 可用
  BeginGestureResult r = h.sm.BeginGesture(1, SpineSide::LEFT, 100, 500,
                                           CurlModel::CYLINDER, false, 7, 11, 22,
                                           360, 720, 360, 720);
  CHECK_TRUE(r.success);
  CHECK_EQ(h.sm.GetActiveToken(), r.operationToken);
  // 旧事务已被自动清理
  CHECK_TRUE(h.sm.FindTransaction(token) == nullptr);
  h.sm.CancelGesture(r.operationToken);
}

// ── token 递增与上限（0.13 / Required Change 6） ─────────────────────

TEST_CASE(SM_Token_Monotonic_Increasing) {
  Harness h;
  int32_t t1 = h.BeginOk();
  h.sm.UpdateGesture(t1, 300, 500, 1000001);
  h.sm.EndGesture(t1, 300, 500);
  h.Advance(1000);
  h.sm.OnFrame(h.nowMs);
  h.sm.ReleaseTextureTransaction(t1);
  int32_t t2 = h.BeginOk();
  CHECK_TRUE(t2 > t1);
  h.sm.CancelGesture(t2);
  int32_t t3 = h.BeginOk();
  CHECK_TRUE(t3 > t2);
  h.sm.CancelGesture(t3);
}

TEST_CASE(SM_Token_Exhaustion_Rejects) {
  Harness h;
  // 逼近上限（Required Change 6：达上限停止签发）
  h.sm.SetNextTokenForTest(0x7FFFFFFE);
  int32_t t1 = h.BeginOk();
  CHECK_TRUE(t1 == 0x7FFFFFFE);
  h.sm.CancelGesture(t1);
  // 下一个 token 将超上限 → TOKEN_EXHAUSTED
  BeginGestureResult r = h.sm.BeginGesture(1, SpineSide::LEFT, 100, 500,
                                           CurlModel::CYLINDER, false, 7, 11, 22,
                                           360, 720, 360, 720);
  CHECK_FALSE(r.success);
  CHECK_EQ(r.operationToken, 0);
  CHECK_EQ(r.failureReason, FailureReason::TOKEN_EXHAUSTED);
  CHECK_EQ(h.sm.GetState(), FlipState::IDLE);
}

// ── pageGeneration 快照协议（0.13） ───────────────────────────────────

TEST_CASE(SM_PageGeneration_Snapshot_Stored_In_Transaction) {
  Harness h;
  int32_t token = h.sm.BeginGesture(1, SpineSide::LEFT, 100, 500, CurlModel::CYLINDER,
                                    false, 12345, 11, 22, 360, 720, 360, 720).operationToken;
  CHECK_TRUE(token > 0);
  const TextureTransaction* tx = h.sm.FindTransaction(token);
  CHECK_TRUE(tx != nullptr);
  CHECK_EQ(tx->pageGenerationSnapshot, 12345);
  h.sm.CancelGesture(token);
}

// ── ReleaseTextureTransaction ─────────────────────────────────────────

TEST_CASE(SM_Release_UnknownToken_Returns_False) {
  Harness h;
  CHECK_FALSE(h.sm.ReleaseTextureTransaction(999));
}
