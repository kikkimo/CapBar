import SwiftUI
import AppKit

enum CapBarSettingsSection: String, CaseIterable { case accounts = "账号", quota = "额度走势", usage = "用量", access = "接口", general = "通用" }

struct CapBarSettingsView: View {
    private enum SizeField: Hashable { case width, height }

    private var group: CapBarSettingsSection { model.settingsSection }
    @State private var customScanInterval = false
    @ObservedObject var model: CapBarViewModel
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @FocusState private var focusedSizeField: SizeField?
    private let secondary = Color(nsColor: .secondaryLabelColor)
    private let line = Color(nsColor: .separatorColor)
    private var maximumWidth: Int { model.maximumPopoverWidth }
    private var maximumHeight: Int { model.maximumPopoverHeight }

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置分组", selection: $model.settingsSection) {
                ForEach(CapBarSettingsSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(.horizontal, 16).padding(.vertical, 9)
            ScrollView {

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(group == .accounts ? "账号与目录" : group == .quota ? "额度与走势" : group == .usage ? "Token 用量" : group == .access ? "外部访问" : "通用").font(.system(size: 14, weight: .bold))
                    Spacer()
                    Button("返回总览") { model.showsSettings = false }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .font(.system(size: 11, weight: .semibold))
                }
                if group == .accounts {
                Text("邮箱、套餐和组织由 Claude Code / Codex 自动识别。首次加入默认目录；移除后不会自动恢复。")
                    .font(.system(size: 11)).foregroundStyle(secondary)
                    .padding(.top, 10).padding(.bottom, 17)

                }
                if group == .quota {
                sectionTitle("刷新行为")
                Toggle("打开弹窗时自动刷新", isOn: Binding(
                    get: { model.settings.autoRefreshOnOpen },
                    set: { model.setAutoRefresh($0) }
                ))
                .font(.system(size: 12, weight: .medium))
                .toggleStyle(.switch)
                .padding(.top, 10)
                Text("关闭时打开弹窗只显示上次快照；下方用量统计的定时采样独立运行。")
                    .font(.system(size: 10)).foregroundStyle(secondary).padding(.top, 4)
                HStack(spacing: 12) {
                    Text("刷新阈值（分钟）").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Stepper(value: Binding(
                        get: { model.settings.refreshThresholdMinutes },
                        set: { model.setThreshold($0) }
                    ), in: 1...120) {
                        Text("\(model.settings.refreshThresholdMinutes)")
                            .font(.system(size: 12)).monospacedDigit()
                    }
                    .frame(width: 105)
                    .disabled(!model.settings.autoRefreshOnOpen)
                }
                .padding(.top, 13)
                Text("开启后逐账号判断：距上次探测超过阈值才刷新。")
                    .font(.system(size: 10)).foregroundStyle(secondary).padding(.top, 4)

                sectionTitle("7 日用量统计").padding(.top, 20)
                Toggle("开启用量统计", isOn: Binding(
                    get: { model.settings.usageStatisticsEnabled },
                    set: { model.setUsageStatisticsEnabled($0) }
                ))
                .font(.system(size: 12, weight: .medium))
                .toggleStyle(.switch)
                .padding(.top, 10)
                Text("开启后，CapBar 运行期间会定时探测各账号额度；从 7 日重置前 \(model.settings.samplingIntervalHours) 小时起每小时采样。退出 CapBar 后停止。探测可能消耗少量额度。")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                HStack(spacing: 12) {
                    Text("定时采样间隔").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Stepper(value: Binding(
                        get: { SamplingInterval.allowedHours.firstIndex(of: model.settings.samplingIntervalHours) ?? 3 },
                        set: { model.setSamplingInterval(SamplingInterval.allowedHours[$0]) }
                    ), in: 0...(SamplingInterval.allowedHours.count - 1)) {
                        Text("\(model.settings.samplingIntervalHours) 小时")
                            .font(.system(size: 12)).monospacedDigit()
                    }
                    .frame(width: 118)
                    .disabled(!model.settings.usageStatisticsEnabled)
                }
                .padding(.top, 13)
                Text("仅可选 1、2、3、4、6、8 小时，默认 4 小时。走势图按所选间隔分组；1 小时采样时按 2 小时绘图。关闭统计也会停止定时采样。")
                    .font(.system(size: 10)).foregroundStyle(secondary).padding(.top, 4)

                }
                if group == .access {
                sectionTitle("外部访问 · MCP / 本地接口").padding(.top, 20)
                Toggle("启用外部访问", isOn: Binding(
                    get: { model.settings.externalAccess.enabled },
                    set: { model.setExternalAccessEnabled($0) }
                ))
                .font(.system(size: 12, weight: .medium)).toggleStyle(.switch).padding(.top, 10)
                Text("允许本机工具只读查询账号身份、额度和已有用量统计。查询不会发起会话。")
                    .font(.system(size: 10)).foregroundStyle(secondary).padding(.top, 4)
                Toggle("允许外部单次刷新", isOn: Binding(
                    get: { model.settings.externalAccess.allowOneShotRefresh },
                    set: { model.setExternalRefreshAllowed($0) }
                ))
                .font(.system(size: 12, weight: .medium)).toggleStyle(.switch).padding(.top, 12)
                .disabled(!model.settings.externalAccess.enabled)
                Text("允许发起一次额度探测，可能消耗少量 token；不会开启定时采样。更改后请重新连接 MCP 客户端。")
                    .font(.system(size: 10)).foregroundStyle(secondary).padding(.top, 4)
                HStack(spacing: 12) {
                    Button("复制 MCP 配置") { model.copyMCPConfiguration() }
                    Button("复制本地接入信息") { model.copyLocalAccessInformation() }
                }
                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor).padding(.top, 12)
                .disabled(!model.settings.externalAccess.enabled)
                Button("重置访问密钥") { model.resetExternalAccessKey() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(secondary)
                    .padding(.top, 9).disabled(!model.settings.externalAccess.enabled)
                if let message = model.externalAccessMessage {
                    Text(message).font(.system(size: 10)).foregroundStyle(secondary).padding(.top, 5)
                }

                }
                if group == .general {
                sectionTitle("启动").padding(.top, 20)
                Toggle("登录时自动启动", isOn: Binding(
                    get: { launchAtLogin.isOn },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .font(.system(size: 12, weight: .medium))
                .toggleStyle(.switch)
                .disabled(!launchAtLogin.canConfigure)
                .padding(.top, 10)
                Text(launchAtLogin.canConfigure
                     ? "默认关闭；开启后随当前用户登录启动，不自动刷新额度。"
                     : "请先将 CapBar 安装到“应用程序”，再开启登录时启动。")
                    .font(.system(size: 10)).foregroundStyle(secondary).padding(.top, 4)
                if let message = launchAtLogin.message {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(launchAtLogin.needsApproval ? Color(nsColor: .systemOrange) : Color(nsColor: .systemRed))
                        .padding(.top, 5)
                }
                if launchAtLogin.needsApproval {
                    Button("打开系统登录项设置") { launchAtLogin.openSystemSettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 6)
                }

                line.frame(height: 1).padding(.top, 20)
                HStack {
                    Text("弹窗尺寸").font(.system(size: 11, weight: .bold)).tracking(0.4)
                    Spacer()
                    Button("恢复最小") {
                        model.setPopoverSize(width: PopoverSize.minimumWidth, height: PopoverSize.minimumHeight)
                    }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Color.accentColor)
                }
                .padding(.top, 8)
                HStack {
                    Text("宽度").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Stepper(value: Binding(
                        get: { model.settings.popoverSize.width },
                        set: { model.setPopoverWidth($0) }
                    ), in: PopoverSize.minimumWidth...maximumWidth, step: 10) {
                        HStack(spacing: 4) {
                            TextField("宽度", text: Binding(
                                get: { model.popoverWidthInput },
                                set: { model.editPopoverWidthInput($0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 62)
                            .focused($focusedSizeField, equals: .width)
                            .onSubmit { model.commitPopoverWidthInput(maximum: maximumWidth) }
                            Text("pt")
                        }
                        .monospacedDigit()
                    }
                    .frame(width: 132)
                }
                .padding(.top, 10)
                HStack {
                    Text("高度").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Stepper(value: Binding(
                        get: { model.settings.popoverSize.height },
                        set: { model.setPopoverHeight($0) }
                    ), in: PopoverSize.minimumHeight...maximumHeight, step: 10) {
                        HStack(spacing: 4) {
                            TextField("高度", text: Binding(
                                get: { model.popoverHeightInput },
                                set: { model.editPopoverHeightInput($0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 62)
                            .focused($focusedSizeField, equals: .height)
                            .onSubmit { model.commitPopoverHeightInput(maximum: maximumHeight) }
                            Text("pt")
                        }
                        .monospacedDigit()
                    }
                    .frame(width: 132)
                }
                .padding(.top, 8)
                Text("最小 448 × 620 pt；调整后立即生效，上限由当前屏幕决定。")
                    .font(.system(size: 10)).foregroundStyle(secondary).padding(.top, 4)

                }
                if group == .accounts {
                sectionTitle("已添加的账号").padding(.top, 20)
                if model.rows.isEmpty {
                    Text("暂无账号目录").font(.system(size: 11)).foregroundStyle(secondary)
                        .padding(.vertical, 12)
                }
                ForEach(model.rows, id: \.account) { row in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text("\(row.account.provider == .claude ? "Claude" : "Codex") · \(row.directoryLabel) · \(row.subtitle)")
                                    .font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
                                    .help(row.account.directory)
                            }
                            Spacer(minLength: 8)
                            Button("移除") { model.removeAccount(row.account) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11)).foregroundStyle(secondary)
                                .disabled(row.isRefreshing)
                                .accessibilityLabel("移除 \(row.title)")
                        }
                        if model.settings.usageStatisticsEnabled {
                            HStack(spacing: 8) {
                                Text("总走势套餐").font(.system(size: 10, weight: .medium)).foregroundStyle(secondary)
                                Spacer(minLength: 6)
                                Picker("总走势套餐", selection: Binding<UsagePlanTier?>(
                                    get: { model.settings.planOverrides.first { $0.account == row.account }?.tier },
                                    set: { model.setPlanOverride($0, for: row.account) }
                                )) {
                                    Text("自动识别").tag(Optional<UsagePlanTier>.none)
                                    ForEach(UsagePlanTier.options(for: row.account.provider), id: \.self) { tier in
                                        Text(tier.displayName).tag(Optional(tier))
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 152)
                                .font(.system(size: 10))
                            }
                            if model.planTier(for: row.account) == nil {
                                Text("当前套餐无法细分，请选择具体档位后参与总走势")
                                    .font(.system(size: 10)).foregroundStyle(Color(nsColor: .systemOrange))
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    line.frame(height: 1)
                }

                sectionTitle("添加目录").padding(.top, 18)
                HStack(alignment: .bottom, spacing: 9) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("服务").font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                        Picker("服务", selection: $model.selectedProvider) {
                            Text("Claude").tag(Provider.claude)
                            Text("Codex").tag(Provider.codex)
                        }
                        .labelsHidden().frame(width: 125)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("配置目录").font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                        TextField("例如 ~/.claude-work", text: $model.directoryInput)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button { model.chooseDirectory() } label: {
                        Image(systemName: "folder")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("选择配置目录")
                    .accessibilityLabel("选择配置目录")
                }
                Button("添加目录") { model.addAccount() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 12)
                if let message = model.settingsMessage {
                    Text(message).font(.system(size: 10)).foregroundStyle(Color(nsColor: .systemRed))
                        .padding(.top, 7)
                }
                }
                if group == .usage { tokenUsageSettings }
                if group == .general {
                line.frame(height: 1).padding(.top, 22)
                HStack {
                    Text("关于 CapBar")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Link("GitHub 仓库", destination: URL(string: "https://github.com/kikkimo/CapBar")!)
                        .font(.system(size: 11))
                }
                .padding(.top, 13)
                }
            }
            .padding(16)
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { launchAtLogin.refresh() }
        .onChange(of: focusedSizeField) { previous, current in
            if previous == .width && current != .width {
                model.commitPopoverWidthInput(maximum: maximumWidth)
            }
            if previous == .height && current != .height {
                model.commitPopoverHeightInput(maximum: maximumHeight)
            }
        }
    }

    private var tokenUsageSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("读取本机日志，统计 token 与 API 等价金额。不调用模型，不消耗模型 token。")
                .font(.system(size: 11)).foregroundStyle(secondary).padding(.top, 9)
            sectionTitle("自动扫描")
            Toggle("开启自动扫描", isOn: Binding(get: { model.settings.tokenUsage.automatic }, set: { model.setTokenAutomatic($0) }))
                .font(.system(size: 12, weight: .medium)).toggleStyle(.switch)
            HStack {
                Text("扫描间隔").font(.system(size: 11))
                Spacer()
                Picker("扫描间隔", selection: Binding(get: {
                    customScanInterval || ![15, 30, 60, 120].contains(model.settings.tokenUsage.intervalMinutes) ? 0 : model.settings.tokenUsage.intervalMinutes
                }, set: { value in customScanInterval = value == 0; if value != 0 { model.setTokenInterval(value) } })) {
                    Text("15 分钟").tag(15); Text("30 分钟 · 默认").tag(30)
                    Text("1 小时").tag(60); Text("2 小时").tag(120); Text("自定义…").tag(0)
                }.labelsHidden().frame(width: 145).controlSize(.small).disabled(!model.settings.tokenUsage.automatic)
            }
            if customScanInterval || ![15, 30, 60, 120].contains(model.settings.tokenUsage.intervalMinutes) {
                Stepper(value: Binding(get: { model.settings.tokenUsage.intervalMinutes }, set: { model.setTokenInterval($0) }), in: 1...1440) {
                    HStack { Text("自定义间隔"); Spacer(); TextField("分钟", value: Binding(get: { model.settings.tokenUsage.intervalMinutes }, set: { model.setTokenInterval($0) }), format: .number).frame(width: 55).textFieldStyle(.roundedBorder); Text("分钟") }
                }.font(.system(size: 11)).disabled(!model.settings.tokenUsage.automatic)
            }
            Text("仅在 CapBar 运行时扫描。关闭后保留统计结果，仍可在用量页手动扫描。")
                .font(.system(size: 10)).foregroundStyle(secondary)
            sectionTitle("日志来源")
            Text("勾选要统计的账号目录。目录只在账号页设置一次，新增或移除账号后列表同步更新。")
                .font(.system(size: 10)).foregroundStyle(secondary)
            if model.settings.accounts.isEmpty { Text("尚未添加账号目录").font(.system(size: 11)).foregroundStyle(secondary) }
            ForEach(model.settings.accounts, id: \.self) { account in
                Toggle(isOn: Binding(get: { !model.settings.tokenUsage.excludedAccounts.contains(account) }, set: { model.setTokenSource(account, enabled: $0) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(account.provider == .claude ? "Claude Code" : "Codex") · \(model.rows.first(where: { $0.account == account })?.title ?? "待识别")").font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(account.directory.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~", options: .anchored)).font(.system(size: 10, design: .monospaced)).foregroundStyle(secondary).lineLimit(1).help(account.directory)
                    }
                }.toggleStyle(.checkbox).padding(.vertical, 4)
            }
            Button("管理账号目录 →") { model.settingsSection = .accounts }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 11))
            Text("API 等价金额为估算，不代表实际账单；未知模型价格单独标记。价格使用随应用附带的离线快照。")
                .font(.system(size: 10)).foregroundStyle(secondary).padding(.top, 4)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            line.frame(height: 1)
            Text(title).font(.system(size: 11, weight: .bold)).tracking(0.4)
        }
    }
}
