import Foundation
import MacBlockerCore

public struct FloatingStatusWindowModel: Codable, Equatable, Sendable {
    public var isVisible: Bool
    public var title: String
    public var message: String
    public var remainingSeconds: TimeInterval?

    public init(
        isVisible: Bool = false,
        title: String = "Blocker Status",
        message: String = "",
        remainingSeconds: TimeInterval? = nil
    ) {
        self.isVisible = isVisible
        self.title = title
        self.message = message
        self.remainingSeconds = remainingSeconds
    }

    public init(status: OverlayStatus?) {
        guard let status else {
            self.init(isVisible: false)
            return
        }
        self.init(
            isVisible: true,
            title: status.title,
            message: status.message,
            remainingSeconds: status.expiresAt.map { max(0, $0.timeIntervalSinceNow) }
        )
    }
}
