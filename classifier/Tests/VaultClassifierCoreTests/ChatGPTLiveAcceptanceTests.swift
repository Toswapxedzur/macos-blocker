import Foundation
import XCTest
@testable import VaultClassifierCore
@testable import VaultClassifierResearch

/// Explicitly enabled, bounded integration acceptance. Real credentials stay in
/// the selected test host's private Account directory. The active sign-in URL
/// can be opened through a same-port SSH loopback forward; it is not a token.
final class ChatGPTLiveAcceptanceTests: XCTestCase {
    func testLiveOptionalProvider() async throws {
        guard let path = ProcessInfo.processInfo.environment["VAULT_LIVE_CHATGPT_DIRECTORY"], !path.isEmpty else {
            throw XCTSkip("Real ChatGPT sign-in and plan usage must be explicitly enabled on the test host.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try VaultPrivateFile.createDirectory(at: root)
        let run = root.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        try VaultPrivateFile.createDirectory(at: run)
        let client = try ChatGPTAccountClient(directory: root.appendingPathComponent("Account"), dailyRequestLimit: 3)
        let cancellation = Task {
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: root.appendingPathComponent("cancel.json")),
                   let value = try? JSONSerialization.jsonObject(with: data) as? [String: String], value["runID"] == run.lastPathComponent {
                    await client.shutdown(); return
                }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
        }
        defer { cancellation.cancel() }
        do {
            var status = await client.status()
            if !status.planUsageEnabled {
                let authorization = try await client.beginSignIn()
                let parameters = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let redirect = try XCTUnwrap(parameters.first { $0.name == "redirect_uri" }?.value)
                let port = try XCTUnwrap(URL(string: redirect)?.port)
                let request: [String: Any] = ["authorizationURL": authorization.absoluteString, "callbackPort": port,
                    "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)), "status": "sign-in-required", "runID": run.lastPathComponent]
                let data = try JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted, .sortedKeys])
                let file = root.appendingPathComponent("live-status.json")
                try data.write(to: file, options: .atomic); try VaultPrivateFile.restrict(file)
                print("ChatGPT live acceptance is waiting for sign-in; see the private test host live-status.json.")
                let deadline = ProcessInfo.processInfo.systemUptime + 295
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    if let cancel = try? Data(contentsOf: root.appendingPathComponent("cancel.json")),
                       let object = try? JSONSerialization.jsonObject(with: cancel) as? [String: String], object["runID"] == run.lastPathComponent {
                        throw CancellationError()
                    }
                    status = await client.status()
                    if status.connected && status.planUsageEnabled && !status.models.isEmpty { break }
                    if let issue = status.issue { throw NSError(domain: "ChatGPTLiveAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: issue]) }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            try await client.refreshModels()
            status = await client.status()
            guard status.connected, status.planUsageEnabled, let model = status.models.first else { throw CloudClassificationError.signInRequired }
            let coordinator = try LocalClassifierCoordinator(verifiedPackage: SeedPackageLoader.bundled(), stateFile: .init(url: run.appendingPathComponent("state.json")))
            var catalog = coordinator.snapshot().workspaceCatalog
            let tree = TagTreeAsset(id: "live-topics", name: "Live diagnostics", nodes: [
                .init(id: "mathematics", name: "Mathematics"), .init(id: "gaming", name: "Gaming"), .init(id: "cooking", name: "Cooking")])
            catalog.trees.append(tree)
            let dataset = catalog.datasets[0]
            catalog.classifierTypes.append(.init(id: "live-group", name: "Live diagnostics", treeID: tree.id, treeRevision: tree.revision,
                datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformIDs: ["youtube"],
                classificationProvider: .chatGPT, chatGPT: .init(accountID: status.accountID, model: model.identifier)))
            try coordinator.updateWorkspaceCatalog(catalog); coordinator.setCloudEngineResolver(client)
            let local = LiveForbiddenLocalResolver(); coordinator.setOnDeviceLLMEngineResolver(local)
            let titles = ["An introduction to quadratic equations", "Minecraft redstone door tutorial", "How to bake sourdough bread"]
            let expected = ["Mathematics", "Gaming", "Cooking"]
            let start = Date()
            let output = try await coordinator.classifyVideos(platformID: "youtube", items: titles.enumerated().map {
                .init(title: $0.element, entryID: "diagnostic-\($0.offset)", creatorID: "diagnostic-creator")
            })
            let localCalls = await local.calls
            let rows: [[String: Any]] = titles.indices.map { index in
                ["title": titles[index], "expected": expected[index], "tags": output["diagnostic-\(index)"]?.tags.map(\.name) ?? []]
            }
            let result: [String: Any] = ["model": model.identifier, "searchEnabled": false,
                "seconds": Date().timeIntervalSince(start), "localEngineResolutions": localCalls,
                "cases": rows, "scope": "three diagnostic examples; not a production accuracy benchmark"]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: run.appendingPathComponent("result.json"), options: .atomic)
            let finished: [String: Any] = ["status": "response-received", "resultPath": run.appendingPathComponent("result.json").path]
            try JSONSerialization.data(withJSONObject: finished).write(to: root.appendingPathComponent("live-status.json"), options: .atomic)
            XCTAssertEqual(localCalls, 0)
            for index in titles.indices { XCTAssertTrue(output["diagnostic-\(index)"]?.tags.contains { $0.name == expected[index] } == true, "Live diagnostic \(index) did not receive the expected topic") }
            try await client.acknowledgePlanUsage()
            await client.shutdown()
        } catch {
            let failed: [String: Any] = ["status": "failed", "issue": error.localizedDescription, "runID": run.lastPathComponent]
            try? JSONSerialization.data(withJSONObject: failed).write(to: root.appendingPathComponent("live-status.json"), options: .atomic)
            await client.shutdown(); throw error
        }
    }
}

private actor LiveForbiddenLocalResolver: OnDeviceLLMEngineResolving {
    private(set) var calls = 0
    func resolveEngine(forModel fileName: String, configuration: LocalLLMSettings) async throws -> any OnDeviceLLM {
        calls += 1; throw OnDeviceLLMError.notReady("Local inference is forbidden in live cloud acceptance.")
    }
}
