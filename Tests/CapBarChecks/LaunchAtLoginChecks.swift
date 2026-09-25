import Foundation
@testable import CapBarCore

@MainActor private final class FakeLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var afterRegister: LoginItemStatus = .enabled
    var registerCount = 0
    var unregisterCount = 0
    var openedSettingsCount = 0
    var registerError: Error?

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = afterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        status = .notRegistered
    }

    func openSystemSettings() { openedSettingsCount += 1 }
}

@MainActor func runLaunchAtLoginChecks() {
    let installedURL = URL(fileURLWithPath: "/Applications/CapBar.app")
    let temporaryURL = URL(fileURLWithPath: "/Users/example/projects/CapBar/dist/CapBar.app")
    check(LaunchAtLoginPolicy.canRegister(applicationURL: installedURL),
          "installed app may register as a login item")
    check(!LaunchAtLoginPolicy.canRegister(applicationURL: temporaryURL),
          "temporary build cannot become the login item")

    let service = FakeLoginItemService()
    let controller = LaunchAtLoginController(service: service, applicationURL: installedURL)
    check(!controller.isOn && service.registerCount == 0,
          "login startup defaults off and never registers implicitly")
    controller.setEnabled(true)
    check(controller.isOn && service.registerCount == 1,
          "explicit enable registers the installed main app")
    controller.setEnabled(false)
    check(!controller.isOn && service.unregisterCount == 1,
          "explicit disable unregisters the login item")

    service.afterRegister = .requiresApproval
    controller.setEnabled(true)
    check(controller.isOn && controller.needsApproval,
          "pending System Settings approval is visible")
    controller.openSystemSettings()
    check(service.openedSettingsCount == 1,
          "user can open macOS Login Items settings")
    service.status = .notRegistered
    controller.refresh()
    check(!controller.isOn, "external System Settings changes are reflected")

    let temporaryService = FakeLoginItemService()
    let temporary = LaunchAtLoginController(service: temporaryService, applicationURL: temporaryURL)
    temporary.setEnabled(true)
    check(!temporary.isOn && temporaryService.registerCount == 0,
          "temporary app refuses login registration")

    enum TestError: Error { case failure }
    let failingService = FakeLoginItemService()
    failingService.registerError = TestError.failure
    let failing = LaunchAtLoginController(service: failingService, applicationURL: installedURL)
    failing.setEnabled(true)
    check(!failing.isOn && failing.message != nil,
          "registration failures preserve the off state and report an error")
}
