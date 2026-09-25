import SwiftUI
import AppKit

struct CapBarSettingsView: View {
    @ObservedObject var model: CapBarViewModel
    private let secondary = Color(nsColor: .secondaryLabelColor)
    private let line = Color(nsColor: .separatorColor)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("账号与刷新").font(.system(size: 14, weight: .bold))
                    Spacer()
                    Button("返回总览") { model.showsSettings = false }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text("邮箱、套餐和组织由 Claude Code / Codex 自动识别。首次加入默认目录；移除后不会自动恢复。")
                    .font(.system(size: 11)).foregroundStyle(secondary)
                    .padding(.top, 10).padding(.bottom, 17)

                sectionTitle("刷新行为")
                Toggle("打开弹窗时自动刷新", isOn: Binding(
                    get: { model.settings.autoRefreshOnOpen },
                    set: { model.setAutoRefresh($0) }
                ))
                .font(.system(size: 12, weight: .medium))
                .toggleStyle(.switch)
                .padding(.top, 10)
                Text("关闭时只显示上次快照，不在后台定时刷新。")
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

                sectionTitle("已添加的账号").padding(.top, 20)
                if model.rows.isEmpty {
                    Text("暂无账号目录").font(.system(size: 11)).foregroundStyle(secondary)
                        .padding(.vertical, 12)
                }
                ForEach(model.rows, id: \.account) { row in
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
                        Image(systemName: "folder").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain).help("选择配置目录")
                }
                Button("添加目录") { model.addAccount() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 12)
                if let message = model.settingsMessage {
                    Text(message).font(.system(size: 10)).foregroundStyle(Color(nsColor: .systemRed))
                        .padding(.top, 7)
                }
                Button("退出 CapBar") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
                    .padding(.top, 22)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionTitle(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            line.frame(height: 1)
            Text(title).font(.system(size: 11, weight: .bold)).tracking(0.4)
        }
    }
}
