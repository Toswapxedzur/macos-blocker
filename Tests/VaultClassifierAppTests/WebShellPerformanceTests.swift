import Foundation
import WebKit
import XCTest
@testable import VaultClassifierApp

@MainActor
final class WebShellPerformanceTests: XCTestCase {
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        let expectation: XCTestExpectation

        init(expectation: XCTestExpectation) {
            self.expectation = expectation
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            expectation.fulfill()
        }
    }

    /// Stands in for the native `deliverCreatorEntries`: answers a
    /// `loadCreatorEntries` message by pushing the matching full entries back
    /// through the same `receiveCreatorEntries` channel the app uses.
    private final class CreatorEntriesResponder: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var entriesByKey: [String: [[String: Any]]] = [:]

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "vaultClassifier",
                  let body = message.body as? [String: Any],
                  body["action"] as? String == "loadCreatorEntries",
                  let data = body["data"] as? [String: Any],
                  let datasetID = data["datasetID"] as? String,
                  let platformID = data["platformID"] as? String,
                  let creatorID = data["creatorID"] as? String else {
                return
            }
            let payload: [String: Any] = [
                "datasetID": datasetID,
                "platformID": platformID,
                "creatorID": creatorID,
                "entries": entriesByKey["\(datasetID)|\(platformID)|\(creatorID)"] ?? [],
            ]
            guard let script = VaultClassifierWebShell.creatorEntriesJavaScript(payload: payload) else { return }
            webView?.evaluateJavaScript(script) { _, _ in }
        }
    }

    /// Polls a script that returns a count until it is positive, yielding the
    /// main queue so the responder's async delivery can land.
    @discardableResult
    private func waitForPositiveCount(_ script: String, in webView: WKWebView, timeout: TimeInterval = 3) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try await evaluate(script, in: webView) as? Int, value > 0 { return value }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        return (try await evaluate(script, in: webView) as? Int) ?? 0
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    /// One full entry, matching the lazy `webCollectedEntry` projection. Each
    /// fixture creator owns exactly one entry (creator-N ↔ entry-N).
    private func makeEntry(index: Int) -> [String: Any] {
        [
            "id": "entry-\(index)",
            "platformID": "youtube",
            "entryID": "video-\(index)",
            "creatorID": "creator-\(index)",
            "creatorName": "Creator \(index)",
            "entryType": "video",
            "title": "Video \(index)",
            "surface": "feed",
            "text": "Full rendered public description",
            "summary": "Rendered public summary",
            "suppliedTags": ["guide", "video"],
            "canonicalURL": NSNull(),
            "attributes": [:],
            "cachedSourceIconURL": NSNull(),
            "firstObservedAtMilliseconds": index,
            "lastObservedAtMilliseconds": index,
            "observationCount": 1,
        ]
    }

    /// The creator-level primary list the snapshot now carries in place of the
    /// full entries.
    private func creatorProjections(creatorCount: Int) -> [[String: Any]] {
        (0..<creatorCount).map { index in
            [
                "platformID": "youtube",
                "creatorID": "creator-\(index)",
                "creatorName": "Creator \(index)",
                "entryCount": 1,
                "firstObservedAtMilliseconds": index,
                "lastObservedAtMilliseconds": index,
                "cachedSourceIconURL": NSNull(),
                "subscriberCount": NSNull(),
            ]
        }
    }

    /// Full entries keyed as the JS cache keys them, for a test responder that
    /// stands in for the native lazy-load channel.
    private func creatorEntriesByKey(creatorCount: Int, datasetID: String = "dataset", platformID: String = "youtube") -> [String: [[String: Any]]] {
        Dictionary(uniqueKeysWithValues: (0..<creatorCount).map { index in
            ("\(datasetID)|\(platformID)|creator-\(index)", [makeEntry(index: index)])
        })
    }

    private func populatedPayload(creatorCount: Int) -> [String: Any] {
        let tree: [String: Any] = [
            "id": "tree",
            "name": "Tree",
            "revision": 1,
            "nodes": [[
                "id": "tag",
                "name": "Tag",
                "description": NSNull(),
                "parentID": NSNull(),
                "retired": false,
                "lightColorHex": "#DBE5F3",
                "darkColorHex": "#253E62",
                "positionX": 100,
                "positionY": 100,
            ]],
        ]
        let dataset: [String: Any] = [
            "id": "dataset",
            "name": "Dataset",
            "revision": 1,
            "creatorClassifications": [],
            "collectedCreators": creatorProjections(creatorCount: creatorCount),
        ]
        let classifierType: [String: Any] = [
            "id": "type",
            "name": "Type",
            "treeID": "tree",
            "treeRevision": 1,
            "datasetID": "dataset",
            "datasetRevision": 1,
            "applicablePlatformID": "youtube",
            "localModel": NSNull(),
            "selectedLLMProviderProfileID": "gemini",
            "llmAssistDraftConfiguration": NSNull(),
            "llmAssistConfiguration": [
                "providerProfileID": "gemini",
                "modelIdentifier": "gemini-model",
                "dailyTokenLimit": 10_000,
                "maximumOutputTokensPerRequest": 4_096,
                "extraDirection": "",
                "dailyTokensUsed": 0,
                "classificationRequestsPerMinute": 6,
                "queuedCreatorCount": creatorCount,
                "completedToday": 0,
                "lastClassificationOutcome": NSNull(),
                "batchSize": 5,
                "officialContentEvidenceCount": 37,
                "maximumTagCount": 8,
                "restrictToLeafTags": true,
                "webSearchMode": "off",
                "webSearchProviderProfileID": NSNull(),
                "isActive": false,
            ],
            "decisionPriority": ["human", "llmAssist", "localModel"],
        ]
        let binding: [String: Any] = [
            "id": "youtube",
            "name": "YouTube",
            "browser": "Chromium",
            "treeID": "tree",
            "datasetID": "dataset",
            "activeClassifierTypeID": NSNull(),
            "activeModelID": NSNull(),
            "policyID": NSNull(),
            "collectionEnabled": true,
            "sourceKind": "creator",
            "supportsLocalModel": true,
            "supportsLLMAssist": true,
        ]
        let platform: [String: Any] = [
            "id": "youtube",
            "name": "YouTube",
            "browser": "Chromium",
            "sourceKind": "creator",
            "collectorAvailable": true,
            "supportsLocalModel": true,
            "supportsLLMAssist": true,
            "apiProviderType": NSNull(),
        ]
        let assets: [String: Any] = [
            "trees": [tree],
            "datasets": [dataset],
            "models": [],
            "classifierTypes": [classifierType],
            "bindings": [binding],
            "collectionPlatforms": [platform],
            "providerProfiles": [[
                "id": "gemini",
                "name": "Gemini",
                "type": "gemini",
                "hasCredential": true,
            ]],
            "providerProtocols": [
                "gemini": [
                    "supportsLLMConfiguration": true,
                    "credentialRequired": true,
                    "supportsNativeWebSearch": true,
                    "supportsAttachedWebSearchTool": false,
                ]
            ],
            "providerModelCatalogs": ["gemini": ["gemini-model"]],
            "providerModelCapabilities": [
                "gemini": [
                    "gemini-model": [
                        "supportsTools": NSNull(),
                        "supportsNativeWebSearch": false,
                    ]
                ]
            ],
            "providerModelCatalogErrors": [:],
            "loadingProviderModelProfileIDs": [],
            "baseEmbeddings": [],
        ]
        return [
            "workspace": "tagTree",
            "issue": NSNull(),
            "notices": [:],
            "inspect": ["llmRunning": false],
            "policies": ["items": [], "editor": [:]],
            "activity": [
                "settings": [
                    "profile": "balanced",
                    "cacheCapacity": 2_000,
                    "packageUpdateMode": "automatic",
                    "allowIdleWork": false,
                    "allowBackgroundSync": false,
                ]
            ],
            "training": [:],
            "backup": [:],
            "assets": assets,
            "collectionDiagnostics": [],
        ]
    }

    func testPopulatedWorkspacesRenderIncrementallyAndNavigateLocally() async throws {
        let loaded = expectation(description: "web shell loaded")
        let waiter = NavigationWaiter(expectation: loaded)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Serve one chosen creator's entries on demand, standing in for native.
        let responder = CreatorEntriesResponder()
        responder.entriesByKey = creatorEntriesByKey(creatorCount: 120)
        configuration.userContentController.add(responder, name: "vaultClassifier")
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1_200, height: 800), configuration: configuration)
        webView.navigationDelegate = waiter
        responder.webView = webView

        let index = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "index", extension: "html"))
        let indexHTML = try String(contentsOf: index, encoding: .utf8)
        XCTAssertTrue(indexHTML.contains("img-src 'self' data: vaultclassifiersourceicon:"))
        XCTAssertFalse(indexHTML.contains("vaultclassifieravatar:"))
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        await fulfillment(of: [loaded], timeout: 5)

        let update = try XCTUnwrap(VaultClassifierWebShell.stateUpdateJavaScript(payload: populatedPayload(creatorCount: 120)))
        _ = try await evaluate(update, in: webView)

        let treeTagStyleValue = try await evaluate(
            """
            (() => {
              const node = document.querySelector('.tree-map-node');
              const style = getComputedStyle(node);
              return `${style.backgroundColor}|${style.borderRadius}|${style.color}`;
            })();
            """,
            in: webView
        )
        let treeTagStyle = try XCTUnwrap(treeTagStyleValue as? String)
        XCTAssertEqual(treeTagStyle, "rgb(219, 229, 243)|999px|rgb(0, 0, 0)")

        let settingsControls = try await evaluate(
            """
            document.querySelector('[data-action="openUtilityPanel"][data-utility-panel="settings"]').click();
            JSON.stringify({
              bridgeCard: Boolean(document.querySelector('.utility-bridge-card')),
              connectAction: Boolean(document.querySelector('[data-action="connectSharedHub"]')),
              disconnectAction: Boolean(document.querySelector('[data-action="disconnectSharedHub"]'))
            });
            """,
            in: webView
        )
        let settingsJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(try XCTUnwrap(settingsControls as? String).utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(settingsJSON["bridgeCard"] as? Bool, false)
        XCTAssertEqual(settingsJSON["connectAction"] as? Bool, false)
        XCTAssertEqual(settingsJSON["disconnectAction"] as? Bool, false)
        _ = try await evaluate(
            "document.querySelector('[data-action=\"closeUtilityPanel\"]').click();",
            in: webView
        )

        let providerDefault = try await evaluate(
            """
            document.querySelector('[data-action="workspace"][data-workspace="llmAssist"]').click();
            document.querySelector('[data-field="type"]')?.value ?? null;
            """,
            in: webView
        )
        XCTAssertEqual(providerDefault as? String, "")

        let classifierValue = try await evaluate(
            """
            document.querySelector('[data-action="workspace"][data-workspace="browserBridge"]').click();
            JSON.stringify({
              workspace: document.querySelector('[data-editor-panel]').dataset.workspace,
              cards: document.querySelectorAll('.creator-tag-column .creator-tag-card').length,
              decisionCards: document.querySelectorAll('[data-keyed-list] .creator-tag-card').length,
              columnsVirtual: [...document.querySelectorAll('.creator-tag-column')].every((column) => Boolean(column.querySelector('[data-virtual-list]'))),
              officialContentEvidenceCount: document.querySelector('[data-field="llmOfficialContentEvidenceCount"]')?.value || null,
              hasNativeSearchOption: Boolean(document.querySelector('[data-field="llmWebSearchMode"] option[value="providerNative"]')),
              tagPillColor: getComputedStyle(document.querySelector('.creator-tag-tab.tag-pill')).backgroundColor,
              tagPillTextColor: getComputedStyle(document.querySelector('.creator-tag-tab.tag-pill')).color,
              tagPillRadius: getComputedStyle(document.querySelector('.creator-tag-tab.tag-pill')).borderRadius
            });
            """,
            in: webView
        )
        let classifierResult = try XCTUnwrap(classifierValue as? String)
        let classifierJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(classifierResult.utf8)) as? [String: Any]
        )
        XCTAssertEqual(classifierJSON["workspace"] as? String, "browserBridge")
        XCTAssertGreaterThan(classifierJSON["cards"] as? Int ?? 0, 0)
        XCTAssertLessThan(classifierJSON["cards"] as? Int ?? .max, 120)
        // The decisions list is a keyed list: it renders every row (no
        // pagination) so rows can be reconciled per-element and scroll kept.
        XCTAssertGreaterThan(classifierJSON["decisionCards"] as? Int ?? 0, 100)
        // Every decision column is windowed, so the master card count above is a
        // bounded visible slice, not all 120 sources.
        XCTAssertEqual(classifierJSON["columnsVirtual"] as? Bool, true)
        XCTAssertEqual(classifierJSON["officialContentEvidenceCount"] as? String, "37")
        XCTAssertEqual(classifierJSON["hasNativeSearchOption"] as? Bool, false)
        XCTAssertEqual(classifierJSON["tagPillColor"] as? String, "rgb(219, 229, 243)")
        XCTAssertEqual(classifierJSON["tagPillTextColor"] as? String, "rgb(0, 0, 0)")
        XCTAssertEqual(classifierJSON["tagPillRadius"] as? String, "999px")
        // Tagging one source moves just that card between columns and updates the
        // counts, without rebuilding the workspace (no full re-render) — so the
        // cost of a decision is independent of the list size.
        let moveValue = try await evaluate(
            """
            document.querySelector('.classifier-type-workspace').setAttribute('data-move-kept', '1');
            document.querySelector('[data-creator-tag-column="needsDecision"] .creator-tag-card button.primary[data-action="recordCreatorClassification"]').click();
            JSON.stringify({
              needs: document.querySelector('[data-creator-tag-column="needsDecision"] [data-creator-tag-count]').textContent,
              tagged: document.querySelector('[data-creator-tag-column="tagged"] [data-creator-tag-count]').textContent,
              workspaceKept: document.querySelector('.classifier-type-workspace').getAttribute('data-move-kept') === '1'
            });
            """,
            in: webView
        )
        let moveJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(moveValue as? String).utf8)) as? [String: Any]
        )
        XCTAssertEqual(moveJSON["needs"] as? String, "119")
        XCTAssertEqual(moveJSON["tagged"] as? String, "1")
        XCTAssertEqual(moveJSON["workspaceKept"] as? Bool, true)

        _ = try await evaluate(
            "document.querySelector('[data-action=\"workspace\"][data-workspace=\"classificationData\"]').click();",
            in: webView
        )
        // The first source is auto-selected; its entries arrive on the lazy
        // channel, so poll until the detail pane has filled in.
        try await waitForPositiveCount(
            "document.querySelectorAll('.collection-detail .collection-detail-entry').length;",
            in: webView
        )
        let dataValue = try await evaluate(
            """
            JSON.stringify({
              workspace: document.querySelector('[data-editor-panel]').dataset.workspace,
              creatorListOpen: document.querySelector('.collection-creators').open,
              creators: document.querySelectorAll('.collection-creator-row').length,
              detailEntries: document.querySelectorAll('.collection-detail .collection-detail-entry').length,
              masterVirtualList: Boolean(document.querySelector('.collection-master [data-virtual-list]')),
              detailHasVirtualList: Boolean(document.querySelector('.collection-detail [data-virtual-list]')),
              detailList: Boolean(document.querySelector('.collection-detail .collection-detail-list'))
            });
            """,
            in: webView
        )
        let dataResult = try XCTUnwrap(dataValue as? String)
        let dataJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(dataResult.utf8)) as? [String: Any]
        )
        XCTAssertEqual(dataJSON["workspace"] as? String, "classificationData")
        XCTAssertEqual(dataJSON["creatorListOpen"] as? Bool, true)
        // Master list is windowed: only a bounded slice of the 120 sources is
        // in the DOM, and the first source is auto-selected so its lazily
        // loaded entries show in the detail pane.
        XCTAssertGreaterThan(dataJSON["creators"] as? Int ?? 0, 0)
        XCTAssertLessThan(dataJSON["creators"] as? Int ?? .max, 120)
        XCTAssertGreaterThan(dataJSON["detailEntries"] as? Int ?? 0, 0)
        // Only the master stays virtualized; the per-creator detail is a plain
        // on-demand list, so the whole corpus never rides the snapshot.
        XCTAssertEqual(dataJSON["masterVirtualList"] as? Bool, true)
        XCTAssertEqual(dataJSON["detailHasVirtualList"] as? Bool, false)
        XCTAssertEqual(dataJSON["detailList"] as? Bool, true)

        let collapsedCreatorListValue = try await evaluate(
            """
            const creatorList = document.querySelector('.collection-creators');
            creatorList.open = false;
            creatorList.dispatchEvent(new Event('toggle'));
            document.querySelector('[data-action="workspace"][data-workspace="browserBridge"]').click();
            document.querySelector('[data-action="workspace"][data-workspace="classificationData"]').click();
            document.querySelector('.collection-creators').open;
            """,
            in: webView
        )
        XCTAssertEqual(collapsedCreatorListValue as? Bool, false)

        _ = try await evaluate(
            """
            document.querySelector('.collection-creators').open = true;
            document.querySelector('.collection-creators').dispatchEvent(new Event('toggle'));
            document.querySelector('.collection-creator-row').click();
            """,
            in: webView
        )
        // The clicked creator's entries are already cached, but they patch the
        // pane on the same async channel, so poll for the swapped-in entry.
        let selectedEntryCount = try await waitForPositiveCount(
            "document.querySelectorAll('.collection-detail .collection-detail-entry').length;",
            in: webView
        )
        XCTAssertEqual(selectedEntryCount, 1)

        let evidenceValue = try await evaluate(
            """
            const entry = document.querySelector('.collection-detail .collection-detail-entry');
            JSON.stringify({
              text: entry.textContent,
              tags: [...entry.querySelectorAll('.collection-entry-tags span')].map((tag) => tag.textContent)
            });
            """,
            in: webView
        )
        let evidenceJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(try XCTUnwrap(evidenceValue as? String).utf8)
            ) as? [String: Any]
        )
        XCTAssertTrue((evidenceJSON["text"] as? String)?.contains("Full rendered public description") == true)
        XCTAssertEqual(evidenceJSON["tags"] as? [String], ["guide", "video"])

        var newestPayload = populatedPayload(creatorCount: 4)
        newestPayload["workspace"] = "classificationData"
        newestPayload["issue"] = "newest presentation"
        let newestUpdate = try XCTUnwrap(
            VaultClassifierWebShell.stateUpdateJavaScript(
                payload: newestPayload,
                presentationRevision: 12
            )
        )
        _ = try await evaluate(newestUpdate, in: webView)

        var stalePayload = newestPayload
        stalePayload["issue"] = "stale presentation"
        let staleUpdate = try XCTUnwrap(
            VaultClassifierWebShell.stateUpdateJavaScript(
                payload: stalePayload,
                presentationRevision: 11
            )
        )
        _ = try await evaluate(staleUpdate, in: webView)
        let renderedTextValue = try await evaluate("document.body.textContent;", in: webView)
        let renderedText = try XCTUnwrap(renderedTextValue as? String)
        XCTAssertTrue(renderedText.contains("newest presentation"))
        XCTAssertFalse(renderedText.contains("stale presentation"))
    }

    func testApplicablePlatformLocksAfterApprovedDecision() async throws {
        let loaded = expectation(description: "web shell loaded")
        let waiter = NavigationWaiter(expectation: loaded)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1_200, height: 800), configuration: configuration)
        webView.navigationDelegate = waiter
        let index = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "index", extension: "html"))
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        await fulfillment(of: [loaded], timeout: 5)

        // A type on the browser-bridge workspace with one approved decision must
        // lock its applicable-platform control.
        var payload = populatedPayload(creatorCount: 3)
        payload["workspace"] = "browserBridge"
        var assets = try XCTUnwrap(payload["assets"] as? [String: Any])
        var datasets = try XCTUnwrap(assets["datasets"] as? [[String: Any]])
        datasets[0]["creatorClassifications"] = [[
            "id": "decision-0",
            "classifierTypeID": "type",
            "creatorID": "creator-0",
            "creatorName": "Creator 0",
            "platformID": "youtube",
            "treeID": "tree",
            "treeRevision": 1,
            "tags": ["tag"],
            "negativeTags": [],
            "origin": "manual",
            "review": "approved",
            "updatedAtMilliseconds": 1,
        ]]
        assets["datasets"] = datasets
        payload["assets"] = assets
        let update = try XCTUnwrap(VaultClassifierWebShell.stateUpdateJavaScript(payload: payload))
        _ = try await evaluate(update, in: webView)

        let lockedValue = try await evaluate(
            """
            const select = document.querySelector('.classifier-applicable-platform-section [data-field="applicablePlatformID"]');
            JSON.stringify({
              disabled: Boolean(select && select.disabled),
              note: Boolean(document.querySelector('[data-platform-locked]'))
            });
            """,
            in: webView
        )
        let lockedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lockedValue as? String).utf8)) as? [String: Any]
        )
        XCTAssertEqual(lockedJSON["disabled"] as? Bool, true)
        XCTAssertEqual(lockedJSON["note"] as? Bool, true)
    }

    func testTrashTombstoneRendersAndDeleteAsksForName() async throws {
        let loaded = expectation(description: "web shell loaded")
        let waiter = NavigationWaiter(expectation: loaded)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1_200, height: 800), configuration: configuration)
        webView.navigationDelegate = waiter
        let index = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "index", extension: "html"))
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        await fulfillment(of: [loaded], timeout: 5)

        var payload = populatedPayload(creatorCount: 2)
        payload["workspace"] = "browserBridge"
        payload["trash"] = [[
            "id": "trash-1",
            "kind": "classifierType",
            "name": "Trashed Type",
            "deletedAtMilliseconds": 1,
        ]]
        let update = try XCTUnwrap(VaultClassifierWebShell.stateUpdateJavaScript(payload: payload))
        _ = try await evaluate(update, in: webView)

        let tombstone = try await evaluate(
            """
            const box = document.querySelector('.classifier-type-panels .trash-tombstone');
            JSON.stringify({
              name: box ? box.querySelector('.trash-tombstone-name').textContent : null,
              restore: Boolean(box && box.querySelector('[data-action="restoreTrashedEntry"][data-id="trash-1"]')),
              purge: Boolean(box && box.querySelector('[data-action="permanentlyDeleteTrashedEntry"][data-id="trash-1"]'))
            });
            """,
            in: webView
        )
        let tombstoneJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(tombstone as? String).utf8)) as? [String: Any]
        )
        XCTAssertEqual(tombstoneJSON["name"] as? String, "Trashed Type")
        XCTAssertEqual(tombstoneJSON["restore"] as? Bool, true)
        XCTAssertEqual(tombstoneJSON["purge"] as? Bool, true)

        let modalShown = try await evaluate(
            """
            document.querySelector('[data-action="confirmDeleteClassifierType"]').click();
            Boolean(document.querySelector('.deletion-dialog [data-deletion-name-input]'));
            """,
            in: webView
        )
        XCTAssertEqual(modalShown as? Bool, true)
    }

    func testScopedRenderKeepsDomAndUpdatesLiveRegionInPlace() async throws {
        let loaded = expectation(description: "web shell loaded")
        let waiter = NavigationWaiter(expectation: loaded)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1_200, height: 800), configuration: configuration)
        webView.navigationDelegate = waiter
        let index = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "index", extension: "html"))
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        await fulfillment(of: [loaded], timeout: 5)

        var payload = populatedPayload(creatorCount: 3)
        payload["workspace"] = "browserBridge"
        _ = try await evaluate(try XCTUnwrap(VaultClassifierWebShell.stateUpdateJavaScript(payload: payload)), in: webView)

        // Mark stable DOM nodes; a full rebuild would drop the marks.
        _ = try await evaluate(
            "document.querySelector('[data-keyed-list]')?.setAttribute('data-test-kept', '1'); document.querySelector('.llm-classification-metrics')?.setAttribute('data-test-kept', '1');",
            in: webView
        )

        // Change only a live counter (completed today). The render signature is
        // unchanged, so render() must take the fast path — preserve the DOM and
        // update the live region in place.
        var payload2 = payload
        var assets = try XCTUnwrap(payload2["assets"] as? [String: Any])
        var types = try XCTUnwrap(assets["classifierTypes"] as? [[String: Any]])
        var llm = try XCTUnwrap(types[0]["llmAssistConfiguration"] as? [String: Any])
        llm["completedToday"] = 5
        types[0]["llmAssistConfiguration"] = llm
        assets["classifierTypes"] = types
        payload2["assets"] = assets
        _ = try await evaluate(try XCTUnwrap(VaultClassifierWebShell.stateUpdateJavaScript(payload: payload2)), in: webView)

        let result = try await evaluate(
            """
            JSON.stringify({
              listKept: document.querySelector('[data-keyed-list]')?.getAttribute('data-test-kept') || null,
              metricsKept: document.querySelector('.llm-classification-metrics')?.getAttribute('data-test-kept') || null,
              metrics: document.querySelector('.llm-classification-metrics')?.textContent || ''
            });
            """,
            in: webView
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result as? String).utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["listKept"] as? String, "1")
        XCTAssertEqual(json["metricsKept"] as? String, "1")
        XCTAssertTrue((json["metrics"] as? String)?.contains("5") == true)
    }
}
