import Foundation

struct ClaudeObservation: Sendable {
    let windows: [WindowKind: QuotaWindow]
    let observedAt: Date

    static func select(
        _ statusline: ClaudeObservation?,
        _ oauth: ClaudeObservation?,
        identity: AccountIdentity,
        capturedAt: Date
    ) throws -> UsageSnapshot {
        var selected: [QuotaWindow] = []
        for kind in [WindowKind.fiveHour, .sevenDay] {
            let statusWindow = statusline?.windows[kind]
            let oauthWindow = oauth?.windows[kind]
            switch (statusWindow, oauthWindow) {
            case let (status?, oauthWindow?):
                let useOAuth = (oauth?.observedAt ?? .distantPast) >= (statusline?.observedAt ?? .distantPast)
                selected.append(useOAuth ? oauthWindow : status)
            case let (status?, nil):
                selected.append(status)
            case let (nil, oauth?):
                selected.append(oauth)
            case (nil, nil):
                break
            }
        }
        guard !selected.isEmpty else { throw ProbeFailure.transient("Claude quota unavailable") }
        return UsageSnapshot(identity: identity, windows: selected, capturedAt: capturedAt)
    }
}
