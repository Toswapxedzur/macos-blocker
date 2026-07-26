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

    private func populatedPayload(creatorCount: Int) -> [String: Any] {
        let entries: [[String: Any]] = (0..<creatorCount).map { index in
            [
                "id": "entry-\(index)",
                "platformID": "youtube",
                "entryID": "video-\(index)",
                "creatorID": "creator-\(index)",
                "creatorName": "Creator \(index)",
                "entryType": "video",
                "title": "Video \(index)",
                "canonicalURL": NSNull(),
                "attributes": [:],
                "cachedCreatorAvatarURL": NSNull(),
                "firstObservedAtMilliseconds": index,
                "lastObservedAtMilliseconds": index,
                "observationCount": 1,
            ]
        }
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
            "collectedEntries": entries,
        ]
        let classifierType: [String: Any] = [
            "id": "type",
            "name": "Type",
            "treeID": "tree",
            "treeRevision": 1,
            "datasetID": "dataset",
            "datasetRevision": 1,
            "applicablePlatformID": "youtube",
            "localModelID": NSNull(),
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
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1_200, height: 800), configuration: configuration)
        webView.navigationDelegate = waiter

        let index = try XCTUnwrap(VaultClassifierWebShell.bundledWebAssetURL(named: "index", extension: "html"))
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
              cards: document.querySelectorAll('.creator-tag-card').length,
              hasDeferredRows: Boolean(document.querySelector('[data-incremental-list]')),
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
        XCTAssertEqual(classifierJSON["hasDeferredRows"] as? Bool, true)
        XCTAssertEqual(classifierJSON["officialContentEvidenceCount"] as? String, "37")
        XCTAssertEqual(classifierJSON["hasNativeSearchOption"] as? Bool, false)
        XCTAssertEqual(classifierJSON["tagPillColor"] as? String, "rgb(219, 229, 243)")
        XCTAssertEqual(classifierJSON["tagPillTextColor"] as? String, "rgb(0, 0, 0)")
        XCTAssertEqual(classifierJSON["tagPillRadius"] as? String, "999px")
        let initialCardCount = classifierJSON["cards"] as? Int ?? 0
        _ = try await evaluate(
            "document.querySelector('[data-incremental-list]').scrollIntoView({ block: 'center' });",
            in: webView
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let expandedCardValue = try await evaluate("document.querySelectorAll('.creator-tag-card').length;", in: webView)
        let expandedCardCount = try XCTUnwrap(expandedCardValue as? Int)
        XCTAssertGreaterThan(expandedCardCount, initialCardCount)

        let dataValue = try await evaluate(
            """
            document.querySelector('[data-action="workspace"][data-workspace="classificationData"]').click();
            JSON.stringify({
              workspace: document.querySelector('[data-editor-panel]').dataset.workspace,
              creators: document.querySelectorAll('.collection-creator').length,
              entries: document.querySelectorAll('.collection-entry').length,
              hasDeferredRows: Boolean(document.querySelector('[data-incremental-list]'))
            });
            """,
            in: webView
        )
        let dataResult = try XCTUnwrap(dataValue as? String)
        let dataJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(dataResult.utf8)) as? [String: Any]
        )
        XCTAssertEqual(dataJSON["workspace"] as? String, "classificationData")
        XCTAssertGreaterThan(dataJSON["creators"] as? Int ?? 0, 0)
        XCTAssertLessThan(dataJSON["creators"] as? Int ?? .max, 120)
        XCTAssertEqual(dataJSON["entries"] as? Int, 0)
        XCTAssertEqual(dataJSON["hasDeferredRows"] as? Bool, true)

        let expandedEntryValue = try await evaluate(
            """
            const creator = document.querySelector('.collection-creator');
            creator.open = true;
            creator.dispatchEvent(new Event('toggle'));
            document.querySelectorAll('.collection-entry').length;
            """,
            in: webView
        )
        let expandedEntryCount = try XCTUnwrap(expandedEntryValue as? Int)
        XCTAssertEqual(expandedEntryCount, 1)
    }
}
