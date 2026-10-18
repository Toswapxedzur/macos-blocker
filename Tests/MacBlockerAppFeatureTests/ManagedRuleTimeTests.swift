#if os(macOS)
import XCTest
final class ManagedRuleTimeTests: XCTestCase {
    func testManagedTimeNativeContracts() throws { try ManagedRuleTimeChecks.run { _ in } }
}
#endif
