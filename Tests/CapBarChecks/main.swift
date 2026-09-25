import Foundation
@testable import CapBarCore

private(set) var checksRun = 0
private(set) var checksFailed = 0

@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    checksRun += 1
    if !condition() {
        checksFailed += 1
        fputs("FAIL \(file):\(line): \(message)\n", stderr)
    }
}

@MainActor func checkThrows(_ message: String, _ body: () throws -> Void) {
    checksRun += 1
    do {
        try body()
        checksFailed += 1
        fputs("FAIL expected error: \(message)\n", stderr)
    } catch {}
}

let arguments = CommandLine.arguments
let filter: String?
if let index = arguments.firstIndex(of: "--filter"), arguments.indices.contains(index + 1) {
    filter = arguments[index + 1]
} else {
    filter = nil
}

if filter == nil || filter == "ModelTests" {
    runModelChecks()
}
if checksRun == 0 {
    fputs("No checks matched \(filter ?? "all")\n", stderr)
    exit(2)
}
print("\(checksRun) checks, \(checksFailed) failures")
if checksFailed != 0 { exit(1) }
