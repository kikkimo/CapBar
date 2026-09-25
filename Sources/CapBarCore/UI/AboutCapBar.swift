import AppKit

@MainActor enum AboutCapBar {
    static let repositoryURL = URL(string: "https://github.com/kikkimo/CapBar")!

    static var credits: NSAttributedString {
        let text = NSMutableAttributedString(string: "多个账号，一处查看额度。\n")
        text.append(NSAttributedString(
            string: "GitHub 仓库",
            attributes: [
                .link: repositoryURL,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        ))
        return text
    }

    static func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
