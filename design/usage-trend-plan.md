# 7 日用量走势 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task by task. Steps use checkbox syntax for tracking.

**Goal:** 在 CapBar 中提供可关闭的 7 日用量统计、UTC 定时采样、SQLite 历史和逐账号用量走势图。绘图按采样设置采用 2、3、4、6 或 8 小时网格，1 小时采样时仍绘制两小时网格。

**Architecture:** 继续使用 `RefreshCoordinator` 作为唯一探测入口，成功结果写最新 JSON，并在统计开启时追加 7 日额度历史。独立的调度器只决定何时调用刷新，不自行调用 Claude/Codex。纯计算模块按采样设置选择 UTC 绘图网格，从真实采样点生成每区间用量和图表状态；SwiftUI 只负责绘制与悬停。

**Tech Stack:** Swift 6、macOS 14、SwiftUI、系统 SQLite3、现有 `CapBarChecks` 测试执行器。

**Spec:** [usage-trend-spec.md](usage-trend-spec.md)；**视觉稿：** [usage-trend-study.html](usage-trend-study.html)。

## Global Constraints

- 统计默认关闭；间隔只允许 1、2、3、4、6、8 小时，默认 4 小时。
- 账号刷新仍最多 3 次尝试；刷新中去重，全局刷新跳过忙碌账号。
- 历史和测试数据不得包含真实账号邮箱、目录、令牌或组织资料。
- 不修改现有 Claude 双渠道探测、Codex 探测和 JSON 快照格式。
- 图表只使用 7 日窗口，UTC 计算，本地时间展示；缺测不写入虚构 0。

## Review Focus

- 旧 `settings.json` 缺少统计字段：应迁移为关闭和 4 小时，测试属于任务 1。
- 同一账号手动刷新与定时点重叠：应只启动一次，测试属于任务 5。
- 重置前后已用值从 90% 到 95%：旧记录缺少边界采样时仅计重置后观测到的 95%，不自动补旧周期剩余额度；有重置前后近距离采样时，再依据同周期增长趋势判断是否估算补足最后一小段。跨重置区间仍用虚线，测试属于任务 3。
- 应用休眠越过多个点：唤醒仅补采一次，测试属于任务 5。
- 无 7 日额度、SQLite 写失败或记录中断：保留最新 JSON，不虚构图表值，测试属于任务 2、4。

---

### Task 1: 设置与迁移

**Files:** `Sources/CapBarCore/Storage/SettingsStore.swift`；`Tests/CapBarChecks/StorageChecks.swift`。

**Interfaces:** `UserSettings.usageStatisticsEnabled: Bool`，`UserSettings.samplingIntervalHours: Int`，`SamplingInterval.allowed = [1,2,3,4,6,8]`；旧数据由 `decodeIfPresent` 提供默认值。

- [x] 在 `StorageChecks` 添加默认值、往返持久化、旧格式迁移和非法间隔拒绝用例。
- [x] 运行 `swift run CapBarChecks --filter StorageTests`，确认新用例因缺少行为失败。
- [x] 加入模型、解码和验证，再运行同一命令至通过。
- [x] 运行完整 `swift run CapBarChecks`。

### Task 2: SQLite 历史

**Files:** `Package.swift`；新建 `Sources/CapBarCore/Storage/UsageHistoryStore.swift`；`Tests/CapBarChecks/UsageHistoryChecks.swift`；`Tests/CapBarChecks/Runner.swift`。

**Interfaces:** `UsageHistorySample(capturedAt: Date, usedPercent: Double, resetsAt: Date?)`；`UsageHistoryStore.append(account:snapshot:) -> Bool`（缺 7 日窗口返回 false）；`samples(account:from:through:) -> [UsageHistorySample]`。唯一键为服务类型、配置目录和 UTC 采集时间。

- [x] 写临时 SQLite 的追加、同刻去重、分账号查询、缺少 7 日窗口和权限测试。
- [x] 运行 `swift run CapBarChecks --filter UsageHistoryTests`，确认预期失败。
- [x] 用系统 SQLite3 实现独立 actor；不存身份邮件或凭据，文件权限 0600。
- [x] 运行目标测试和完整检查。

### Task 3: 按采样间隔计算区间用量

**Files:** 新建 `Sources/CapBarCore/Domain/UsageTrend.swift`；`Tests/CapBarChecks/UsageTrendChecks.swift`；`Tests/CapBarChecks/Runner.swift`。

**Interfaces:** `UsageTrendCalculator.calculate(samples:intervalHours:endingAt:) -> UsageTrendSeries`；`UsageTrendPoint` 包含 UTC 区间终点、可选用量、可选剩余额度、跨重置和缺测标志；series 包含动态纵轴上限与刻度。

- [x] 分别写 30→50 的 02/04 点各 10、50→90 的 06 点 40、重置 90→5 得 15、重置 90→95 得 105、极端 0→100 得 200 的失败用例。
- [x] 写 UTC 网格、本地跨日、同周期倒退、缺少 resetAt、超过间隔容差、人工中途采样和纵轴刻度用例。
- [x] 运行 `swift run CapBarChecks --filter UsageTrendTests` 见红，再实现分段线性插值和缺测标志。
- [x] 运行目标测试及完整检查。
- [x] 后续修订：1/2 小时采样对应 84 个两小时格，3/4/6/8 小时采样分别对应 56/42/28/21 个同长度格；加入人工采样跨网格插值与缓存边界回归检查。

### Task 4: 刷新结果写双存储

**Files:** `Sources/CapBarCore/Refresh/RefreshCoordinator.swift`；`Tests/CapBarChecks/RefreshCoordinatorChecks.swift`。

**Interfaces:** 为 coordinator 注入可选 `UsageHistoryStore`；`requestRefresh(_:recordHistory:)` 保持现有调用可用；全部刷新及弹窗刷新从传入 `UserSettings` 判断是否记录历史。

- [x] 写人工/自动成功写 SQLite 与 JSON、失败不写 SQLite、缺少 7 日窗口、不覆盖旧快照、忙碌账号不重复写入测试。
- [x] 跑 `RefreshCoordinatorTests` 见红；让所有成功探测经同一保存路径，历史写入失败时明确错误但保留 JSON 最新快照。
- [x] 跑目标测试及完整检查。

### Task 5: 定时调度与恢复

**Files:** 新建 `Sources/CapBarCore/Refresh/UsageSamplingSchedule.swift`、`UsageSamplingController.swift`；`Sources/CapBarCore/UI/CapBarAppLauncher.swift`；`Tests/CapBarChecks/UsageSamplingChecks.swift`；`Tests/CapBarChecks/Runner.swift`。

**Interfaces:** 纯计划器计算下一个 UTC 常规点、已知 resetAt 的 N 小时前逐小时点及 resetAt 前后各 5 分钟的点；控制器维护每账号下一次应采样时间，调度到期时调用 coordinator，不拥有新的探测客户端。

- [x] 写六档 UTC 点、启用后的首个点、6/8 小时重置窗口、重合去重、禁用停止、睡眠唤醒与重启一次补采测试。
- [x] 跑 `UsageSamplingTests` 见红；实现计划器与控制器，并在应用启动、唤醒、退出时接线。
- [x] 跑目标测试及完整检查。

### Task 6: SwiftUI 设置与走势图

**Files:** `Sources/CapBarCore/UI/SettingsView.swift`、`CapBarViewModel.swift`、`PopoverView.swift`；新建 `Sources/CapBarCore/UI/UsageTrendChart.swift`；`Tests/CapBarChecks/ViewModelChecks.swift`、`PopoverModelChecks.swift`。

**Interfaces:** ViewModel 暴露统计开启、六档间隔、全局显示模式、逐账号趋势数据；chart 接受 `UsageTrendSeries` 和本地 Calendar，绘制折线、虚线、刻度、逐日日期与最近点悬停提示。

- [x] 写设置档位步进、统计关闭隐藏走势图、全局切换、定时中刷新按钮禁用的失败检查。
- [x] 跑目标检查见红；实现设置与 ViewModel 绑定，再按 HTML 实现 84 pt 两种内容区域和悬停图。
- [x] 运行检查，并用现有渲染入口检查 448 × 620 pt 明暗外观与滚动，人工检查横轴日期和 tooltip。

### Task 7: 完整验证与交付

**Files:** `design/usage-trend-spec.md`、`design/usage-trend-plan.md`、必要的发布说明；不写入本机采样文件。

- [x] 运行完整 `swift run CapBarChecks`、构建、现有打包/自检流程。
- [x] 检查源码、测试、设计稿与 git diff 中不存在个人账号信息或令牌。
- [ ] 在功能分支提交变更；若创建 PR，则等待 CI 并把 PR 附加到任务。发布与合并遵循用户后续指示。
