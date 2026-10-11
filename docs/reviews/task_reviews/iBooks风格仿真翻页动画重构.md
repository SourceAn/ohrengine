# Review Result

Status:
FAIL


# Findings


## Critical

1. B1→B3 的互斥约束与状态转移表仍然矛盾。0.10 在 B1 后将状态切换为 `Idle`，而 `Idle` 的 `beginGesture` 仅检查是否存在“活跃 token”；这会允许 ArkTS 在完成回调到达、但尚未完成 `pageGeneration` 校验、`turnPage()` 和 `refreshPage()` 的窗口内启动新手势。0.11 又要求该窗口禁止新的 `beginGesture`。必须增加显式的 `PendingCommit`/提交屏障状态，或定义等价的不可绕过 guard，并补齐状态表、超时和新手势拒绝语义。

2. 纹理事务只有生命周期描述，没有可执行的跨 ArkTS/Native 交接 API。任务要求 ArkTS 先完成截图和纹理上传，Native 再按 `operationToken` 登记两张纹理及其 handle，但 `beginGesture` 签名没有纹理 handle、`registerTextureTransaction` 等参数/API，现有 API 列表也没有定义上传完成通知、所有权转移、线程归属和失败回滚。没有这部分契约，`beginReboundRecovery` 无法保证复用原纹理，补救闭环不能实现。必须明确纹理登记/转移接口、调用顺序、失败语义和资源所有权。

3. `beginReboundRecovery(prevToken, direction)` 生成新 `operationToken`，但纹理事务仍以 `prevToken` 为 key；随后 `releaseTextureTransaction(token)`、完成回调 token、ArkTS 当前手势 token 到底使用旧 token还是新 token没有统一定义。按当前文字，补救完成后可能无法释放旧事务，或旧回调/新回调被错误丢弃。必须定义 `prevToken` 与 recovery token 的关联记录、回调 token、释放 API 的 token 语义，以及补救期间禁止再次 B2 提交的规则。

4. B1 清屏发生在 ArkTS `turnPage()`/`refreshPage()` 之前，期间仍显示旧 Canvas 内容。文档同时要求提交时机严格对齐，因此必须明确是否接受最多一帧旧内容，或调整清屏/Canvas 刷新的屏障顺序。


## Warning

1. v3 已规定 TSFN 随 Surface 创建并在 Surface 销毁时释放，但未明确 Surface 销毁发生在 `Dragging`/settling/pending-commit 各阶段时，当前操作、纹理事务、定时器和 ArkTS 本地 token 的清理顺序。应增加生命周期矩阵和可验证的最终状态。

2. `pageGeneration` 的快照在 ArkTS 持有，但纹理事务描述又要求 Native 保存该快照；`beginGesture` API 没有 `pageGeneration` 参数，也未定义 Native 获取/查询该值的接口。应明确该值仅由 ArkTS 保存，或补充版本化的快照传递/校验协议，避免出现两份未同步的真源。

3. 900ms 超时后降级为 `rebound` 可以保证不误提交，但若完成回调因 TSFN 调度/销毁而未到达，ArkTS 不会调用 `releaseTextureTransaction`，只能依赖保留期清理；应明确该路径的日志、指标和用户可见行为，并验证不会永久阻塞后续提交屏障。

4. `operationToken` 的“单调递增且范围为 `[1, 2^31-1]`”未定义达到上限后的处理。应规定安全回绕/拒绝策略，并保证回绕不会与仍处于保留期的 token 冲突。

5. “B0 终帧与静态页面逐像素一致或视觉不可区分”与当前通过纹理采样、合成 shader 生成终帧的实现边界仍不够可测。应明确截图对比的容差、颜色空间、透明度和允许的误差阈值，否则验收结论会依赖主观观察。

6. Phase A 允许状态机骨架与纹理事务机制落地，但 Phase B 又要求 Cone/Hybrid 与分页提交链路一并进入；建议把“提交屏障和补救闭环”的可执行接口评审列为 Phase B 前置门禁，而不只以代码已实现作为条件。


## Suggestion

1. 先独立完成 Cylinder 重构、坐标/单位契约、状态机骨架、方向推导单测和性能采集拆分，再进入 Cone/Hybrid。

2. 建议将一次操作封装为显式 `FlipOperationContext`，统一保存 operation token、recovery token、pageGeneration、纹理事务状态和提交阶段，减少 ArkTS 与 Native 各自维护字段造成的语义漂移。

3. 为 `turnPage()` 失败和重排竞态增加一次性补救状态，不允许补救路径递归启动；同时为每个屏障记录时间戳，直接产出 B1→B3、补救和最终兜底的诊断数据。


# Required Changes

1. 增加 B1→B3 提交屏障的显式状态或不可绕过 guard，更新完整状态转移表，禁止窗口内启动新手势。
2. 补齐纹理事务登记/所有权转移/释放 API，定义纹理 handle 的传递、线程、失败回滚和 Surface 销毁语义。
3. 统一原始 token 与 recovery token 的关联及所有 API/回调/释放调用使用的 token，增加状态机和异步回调单测。
4. 明确 `pageGeneration` 快照的唯一持有方和跨层校验协议，避免任务同时要求 ArkTS 与 Native 各存一份但没有同步接口。
5. 补充 TSFN 在各生命周期阶段不可用时的清理、超时、纹理释放和最终状态规则。
6. 补充 token 达到上限后的处理策略，以及终帧截图对比的客观容差和测试口径。
7. 在进入 Phase B 前，对上述接口和状态闭环完成一次独立架构复审；未通过前不得合入 Cone/Hybrid 或分页提交链路改造。


# Reviewer Decision

不允许直接执行完整开发。允许先执行不涉及正式分页提交的前置设计、Cylinder 结构拆分、坐标/单位契约、状态机骨架和离线测试；完成 Required Changes 并复审通过后，才允许进入 Cone/Hybrid 及分页提交链路改造。
