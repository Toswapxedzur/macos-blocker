import Foundation
import VaultClassifierCore

enum TaggingRetry {
    static func isTransient(_ error: Error) -> Bool {
        if let http = error as? ProviderTestHTTPError, case .status(let status) = http {
            return status == 408 || (500...599).contains(status)
        }
        if let url = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(url.code)
        }
        return (error as? ChatGPTPlanError) == .transientResponse
    }

    static func wait(_ policy: TaggingRetryPolicy) async throws {
        try await Task.sleep(nanoseconds: UInt64(policy.intervalSeconds) * 1_000_000_000)
    }
}
