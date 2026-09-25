import Combine
import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor private struct SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum LaunchAtLoginPolicy {
    static func canRegister(applicationURL: URL) -> Bool {
        applicationURL.standardizedFileURL.path == "/Applications/CapBar.app"
    }
}

@MainActor final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var message: String?
    let canConfigure: Bool
    private let service: any LoginItemService

    init(service: any LoginItemService = SystemLoginItemService(),
         applicationURL: URL = Bundle.main.bundleURL) {
        self.service = service
        self.canConfigure = LaunchAtLoginPolicy.canRegister(applicationURL: applicationURL)
        self.status = service.status
    }

    var isOn: Bool {
        canConfigure && (status == .enabled || status == .requiresApproval)
    }

    var needsApproval: Bool { canConfigure && status == .requiresApproval }

    func refresh() {
        status = service.status
        if needsApproval {
            message = "需要在系统设置中允许 CapBar 登录时启动。"
        } else {
            message = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard canConfigure else {
            message = "请先将 CapBar 安装到“应用程序”后再开启。"
            return
        }
        do {
            if enabled {
                if status == .notRegistered || status == .notFound { try service.register() }
            } else if status != .notRegistered {
                try service.unregister()
            }
            refresh()
        } catch {
            status = service.status
            message = "无法更改登录项：\(error.localizedDescription)"
        }
    }

    func openSystemSettings() { service.openSystemSettings() }
}
