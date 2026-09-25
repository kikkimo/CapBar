import CapBarCore
import Foundation

@main struct CapBarMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-check") {
            guard CapBarAppLauncher.selfCheck() else { fputs("CapBar bundle check failed\n", stderr); exit(1) }
            print("CapBar bundle OK")
            return
        }
        CapBarAppLauncher.run()
    }
}
