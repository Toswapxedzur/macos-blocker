import Foundation

/// Keeps WebKit presentation strictly downstream from authoritative state.
/// At most one script may render at a time; requests received before that
/// render completes collapse into one newest-state delivery.
final class LatestWebStateDelivery {
    typealias Scheduler = (@escaping () -> Void) -> Void
    typealias ScriptBuilder = (_ presentationRevision: UInt64) -> String?
    typealias Evaluator = (_ script: String, _ completion: @escaping () -> Void) -> Void

    private let schedule: Scheduler
    private let makeScript: ScriptBuilder
    private let evaluate: Evaluator
    private var requestedRevision: UInt64 = 0
    private var deliveredRevision: UInt64 = 0
    private var deliveryScheduled = false
    private var deliveryInFlight = false
    private var activeDeliveryRevision: UInt64?
    /// While the page cannot be seen (another scene is in front, or the window
    /// is closed / occluded) no snapshot is built: building + serialising one
    /// costs ~150 ms of main-thread time per classification burst, all for a
    /// render nobody sees. Requests keep counting; the newest state is delivered
    /// once, when the page shows again.
    private(set) var suspended = false

    func setSuspended(_ flag: Bool) {
        guard flag != suspended else { return }
        suspended = flag
        if !flag { scheduleIfNeeded() }
    }

    init(
        schedule: @escaping Scheduler,
        makeScript: @escaping ScriptBuilder,
        evaluate: @escaping Evaluator
    ) {
        self.schedule = schedule
        self.makeScript = makeScript
        self.evaluate = evaluate
    }

    func request() {
        requestedRevision &+= 1
        scheduleIfNeeded()
    }

    func recoverAfterWebContentProcessTermination() {
        activeDeliveryRevision = nil
        deliveryInFlight = false
        requestedRevision &+= 1
        scheduleIfNeeded()
    }

    private func scheduleIfNeeded() {
        guard !suspended,
              !deliveryScheduled,
              !deliveryInFlight,
              deliveredRevision < requestedRevision else {
            return
        }
        deliveryScheduled = true
        schedule { [weak self] in
            self?.beginLatestDelivery()
        }
    }

    private func beginLatestDelivery() {
        deliveryScheduled = false
        guard !suspended,
              !deliveryInFlight,
              deliveredRevision < requestedRevision else {
            return
        }
        let revision = requestedRevision
        guard let script = makeScript(revision) else {
            deliveredRevision = revision
            scheduleIfNeeded()
            return
        }
        deliveryInFlight = true
        activeDeliveryRevision = revision
        evaluate(script) { [weak self] in
            guard let self,
                  self.activeDeliveryRevision == revision else {
                return
            }
            self.activeDeliveryRevision = nil
            self.deliveryInFlight = false
            self.deliveredRevision = max(self.deliveredRevision, revision)
            self.scheduleIfNeeded()
        }
    }
}
