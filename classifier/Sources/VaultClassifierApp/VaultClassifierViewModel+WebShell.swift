import Foundation
import VaultClassifierCore
import VaultClassifierResearch
import VaultClassifierBridge

// The untyped web-shell RPC: the state snapshot the WebView renders and the string-keyed action dispatcher, plus the web input coercion helpers.
// Split out of VaultClassifierApp.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour — pinned by ViewModelCharacterizationTests.
@MainActor
extension VaultClassifierViewModel {
    /// The WKWebView receives only the bounded local state necessary to render
    /// this development shell. Browser evidence, API keys, pairing material,
    /// stable identifiers stay in native storage.
    func webSnapshot(includeCollections: Bool = true) -> [String: Any] {
        let state = localState ?? coordinator?.snapshot()
        let backup = state?.backupConfiguration
        let notices: [String: Any] = [
            "backup": backupNotice ?? NSNull(),
        ]
        let catalog = state?.workspaceCatalog ?? .starter()
        let settingsPayload: [String: Any] = [
            "classificationEnabled": state?.settings.classificationEnabled ?? true,
        ]
        let backupPayload: [String: Any] = [
            "hasOwnerCode": hasBackupOwnerCode,
            "unlocked": backupUnlocked,
            "enabled": backupEnabled,
            "directory": backupDirectory,
            "savedEnabled": backup?.isEnabled ?? false,
        ]
        var assets = [String: Any]()
        assets["trees"] = catalog.trees.map { tree in
                ["id": tree.id, "name": tree.name, "revision": tree.revision, "nodes": tree.nodes.enumerated().map { index, node -> [String: Any] in
                    let position = node.resolvedCanvasPosition(index: index)
                    return ["id": node.id, "name": node.name, "description": node.description ?? NSNull(), "parentID": node.parentID ?? NSNull(), "retired": node.isRetired, "lightColorHex": node.lightColorHex ?? NSNull(), "darkColorHex": node.darkColorHex ?? NSNull(), "positionX": position.x, "positionY": position.y]
                }] as [String: Any]
            }
        assets["datasets"] = catalog.datasets.map { dataset in
                [
                    "id": dataset.id,
                    "name": dataset.name,
                    "revision": dataset.revision,
                    // Collected entries per platform (the Collection page shows them).
                    "entryCounts": Dictionary(grouping: dataset.collectedEntries, by: \.platformID).mapValues(\.count),
                ] as [String: Any]
            }
        assets["classifierTypes"] = catalog.classifierTypes.map { classifierType in
                [
                    "id": classifierType.id,
                    "name": classifierType.name,
                    "order": classifierType.order,
                    "treeID": classifierType.treeID,
                    "treeRevision": classifierType.treeRevision,
                    "datasetID": classifierType.datasetID,
                    "datasetRevision": classifierType.datasetRevision,
                    "applicablePlatformIDs": classifierType.applicablePlatformIDs,
                    "isPaused": classifierType.isPaused,
                    "classificationProvider": classifierType.classificationProvider.rawValue,
                    "apiKey": ["profileID": classifierType.apiKey.profileID, "model": classifierType.apiKey.model, "reasoningEffort": classifierType.apiKey.reasoningEffort.rawValue],
                    "chatGPT": ["accountID": classifierType.chatGPT.accountID, "model": classifierType.chatGPT.model, "reasoningEffort": classifierType.chatGPT.reasoningEffort.rawValue] as [String: Any],
                    "tagging": [
                        "houseRules": classifierType.tagging.houseRules,
                        "strictness": classifierType.tagging.strictness.rawValue,
                        "minimumTagsOverride": classifierType.tagging.minimumTagsOverride.map { $0 as Any } ?? NSNull(),
                        "maximumTagsOverride": classifierType.tagging.maximumTagsOverride.map { $0 as Any } ?? NSNull(),
                    ] as [String: Any],
                ] as [String: Any]
            }
        assets["chatGPT"] = ["connected": chatGPTStatus.connected, "accountID": chatGPTStatus.accountID,
            "email": chatGPTStatus.email, "planUsageEnabled": chatGPTStatus.planUsageEnabled,
            "signingIn": chatGPTStatus.signingIn, "requestsToday": chatGPTStatus.requestsToday,
            "needsRetry": chatGPTStatus.needsRetry, "failedItems": failedCloudClassifications.count,
            "needsWelcome": chatGPTStatus.needsWelcome,
            "issue": chatGPTStatus.issue ?? NSNull(),
            "dailyRequestLimit": state?.settings.chatGPTDailyRequestLimit.map { $0 as Any } ?? NSNull(),
            "models": chatGPTStatus.models.map { ["id": $0.identifier, "name": $0.displayName] }] as [String: Any]
        var classificationCapabilities: [String: Any] = [:]
        func capability(_ provider: APIKeyProviderType?, _ model: String) -> [String: Any] {
            ["searchCompatible": ClassificationModelPolicy.searchCompatible(provider: provider, model: model),
             "reasoningEfforts": ClassificationModelPolicy.efforts(provider: provider, model: model).map(\.rawValue)]
        }
        for model in chatGPTStatus.models { classificationCapabilities["chatgpt:" + model.identifier] = capability(nil, model.identifier) }
        for profile in catalog.providerProfiles where APIKeyClassificationClient.supports(profile.type) {
            for model in providerModelCatalogs[profile.id] ?? [] { classificationCapabilities["api:" + profile.id + ":" + model.identifier] = capability(profile.type, model.identifier) }
        }
        assets["classificationModelCapabilities"] = classificationCapabilities
        assets["apiKeyClassification"] = ["failedProfileIDs": Array(apiKeyClassificationStatus?.failedProfileIDs ?? []), "requestsToday": apiKeyClassificationStatus?.requestsToday ?? 0]
        assets["providerProfiles"] = catalog.providerProfiles.map { profile in
                let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
                return [
                    "id": profile.id,
                    "name": profile.name,
                    "type": profile.type.rawValue,
                    "defaultModelIdentifier": profile.type.defaultModelIdentifier,
                    "customEndpoint": profile.customEndpoint ?? NSNull(),
                    "protocolConfiguration": profile.protocolConfiguration,
                    "testModelIdentifier": profile.testModelIdentifier ?? NSNull(),
                    "credential": profile.credential ?? "",
                    "hasCredential": !descriptor.credentialFields.isEmpty && profile.credential?.isEmpty == false,
                    "testing": testingProviderProfileIDs.contains(profile.id),
                    "testSucceeded": successfulProviderTestProfileIDs.contains(profile.id),
                ] as [String: Any]
            }
        assets["providerRequestRecords"] = includeCollections ? catalog.providerRequestRecords.map { record in
                [
                    "id": record.id,
                    "profileID": record.profileID,
                    "provider": record.provider,
                    "model": record.model,
                    "operation": record.operation,
                    "endpoint": record.endpoint,
                    "method": record.method,
                    "statusCode": record.statusCode ?? NSNull(),
                    "responseShape": record.responseShape ?? NSNull(),
                    "durationMilliseconds": record.durationMilliseconds,
                    "tokenCount": record.tokenCount ?? NSNull(),
                    "classifierTypeID": record.classifierTypeID ?? NSNull(),
                    "outcome": record.outcome,
                    "createdAtMilliseconds": record.createdAtMilliseconds,
                ] as [String: Any]
            } : []
        var summaries: [String: [String: Any]] = [:]
        for record in catalog.providerRequestRecords {
            var summary = summaries[record.profileID] ?? ["tokenTotal": 0, "calls": 0, "latestTime": Int64(0)]
            summary["tokenTotal"] = (summary["tokenTotal"] as? Int ?? 0) + (record.tokenCount ?? 0)
            if ["readPublicContent", "searchWeb", "search-creator-web"].contains(record.operation), record.statusCode != nil {
                summary["calls"] = (summary["calls"] as? Int ?? 0) + 1
            }
            if let shape = record.responseShape, !shape.isEmpty, record.createdAtMilliseconds >= (summary["latestTime"] as? Int64 ?? 0) {
                summary["latestTime"] = record.createdAtMilliseconds; summary["responseShape"] = shape
            }
            summaries[record.profileID] = summary
        }
        assets["providerRequestSummaries"] = summaries
        assets["providerProtocols"] = Dictionary(uniqueKeysWithValues: APIKeyProviderType.allCases
                .map { type -> (String, [String: Any]) in
                    let descriptor = ProviderProtocolRegistry.descriptor(for: type)
                    return (type.rawValue, [
                        "identifier": descriptor.identifier,
                        "revision": descriptor.revision,
                        "family": descriptor.family.rawValue,
                        "supportsLLMConfiguration": descriptor.supportsLLMConfiguration,
                        "supportsGenerateText": ProviderGenerationProtocol.supportsGeneration(
                            profile: APIKeyProviderProfile(type: type)
                        ),
                        "supportsPlatformData": descriptor.requestFormats.contains(where: { $0.operation == .readPublicContent }),
                        "supportsNativeWebSearch": type.supportsProviderNativeWebSearch,
                        "supportsAttachedWebSearchTool": type.supportsAttachedWebSearchTool,
                        "retiredSearchProvider": type.isRetiredSearchProvider,
                        "allowsEndpointOverride": descriptor.allowsEndpointOverride,
                        "credentialRequired": !descriptor.credentialFields.isEmpty,
                        "credentialFields": descriptor.credentialFields.map(\.rawValue),
                        "configurationRequirements": descriptor.configurationRequirements.map { requirement in
                            [
                                "field": requirement.field.rawValue,
                                "defaultValue": requirement.defaultValue ?? NSNull(),
                                "requiredForDispatch": requirement.isRequiredForDispatch,
                            ] as [String: Any]
                        },
                    ])
                })
        assets["bindings"] = catalog.bindings.map { binding in
                let definition = CollectionPlatformRegistry.definition(for: binding.id)
                return ["id": binding.id, "name": binding.name, "browser": binding.browser, "treeID": binding.treeID, "datasetID": binding.datasetID, "activeClassifierTypeID": binding.activeClassifierTypeID ?? NSNull(), "collectionEnabled": binding.collectionEnabled, "collectionKeepDays": binding.collectionKeepDays, "sourceKind": definition?.sourceKind.rawValue ?? CollectionSourceKind.creator.rawValue, "supportsLocalModel": definition?.supportsLocalModel ?? false] as [String: Any]
            }
        assets["collectionKeepDays"] = catalog.collectionKeepDays
        assets["collectionPlatforms"] = CollectionPlatformRegistry.definitions.map { definition in
                ["id": definition.id, "name": definition.name, "browser": definition.browser, "sourceKind": definition.sourceKind.rawValue, "collectorAvailable": definition.collectorAvailable, "supportsLocalModel": definition.supportsLocalModel, "apiProviderType": definition.apiProviderType?.rawValue ?? NSNull()] as [String: Any]
            }
        assets["providerModelCatalogs"] = providerModelCatalogs.mapValues { $0.map(\.identifier) }
        assets["providerModelCapabilities"] = providerModelCatalogs.mapValues { entries in
            Dictionary(uniqueKeysWithValues: entries.map { entry in
                (
                    entry.identifier,
                    [
                        "supportsTools": entry.supportsTools ?? NSNull(),
                        "supportsNativeWebSearch": entry.supportsNativeWebSearch ?? NSNull(),
                    ] as [String: Any]
                )
            })
        }
        assets["providerModelCatalogErrors"] = providerModelCatalogErrors
        assets["loadingProviderModelProfileIDs"] = Array(loadingProviderModelProfileIDs).sorted()
        // Collection diagnostics are recorded to the local
        // `collection-diagnostics.json` log only. They are deliberately not
        // included in the web snapshot, so they never reach the WebView state
        // or the browser bridge.
        return [
            "workspace": workspace.rawValue,
            "issue": issue ?? NSNull(),
            "notices": notices,
            "settings": settingsPayload,
            "backup": backupPayload,
            "assets": assets,
        ]
    }

    /// The web renderer is a bundled local asset, but its messages are still
    /// treated as untrusted UI input. Keep the surface small and bounded so it
    /// cannot become another native IPC or provider-control path.
    /// Returns whether the web shell should publish a new snapshot.
    func performWebAction(_ action: String, data: [String: Any]) -> Bool {
        guard !isShuttingDown else { return false }
        do {
            switch action {
            case "state":
                refreshLocalState()
            case "workspace":
                let selected = try webString(data, key: "workspace", limit: 32)
                guard let value = Workspace(rawValue: selected) else { throw WebBridgeInputError.invalidChoice("workspace") }
                workspace = value
                // The WebView already owns the current bounded snapshot and
                // switches workspaces optimistically. Avoid echoing the same
                // multi-megabyte state back across the bridge for navigation —
                // while it is open.
                return false
            case "clearCollectedData":
                clearCollectedData(platformID: try webString(data, key: "platformID", limit: 64))
            case "setCollectionKeep":
                guard let days = (data["days"] as? NSNumber)?.intValue else { throw WebBridgeInputError.missingValue("days") }
                setCollectionKeep(platformID: try webOptionalString(data, key: "platformID", limit: 64), days: days)
            case "setCollectionEnabled":
                setCollectionEnabled(
                    platformID: try webString(data, key: "platformID", limit: 64),
                    enabled: try webBool(data, key: "enabled")
                )
            case "createClassifierType":
                createClassifierType(
                    name: try webString(data, key: "name", limit: ClassifierTypeAsset.maximumNameLength),
                    platformIDs: try webStringArray(data, key: "platformIDs", limit: 16, elementLimit: 64)
                )
            case "reorderClassifierTypes":
                reorderClassifierTypes(orderedIDs: try webStringArray(data, key: "orderedIDs", limit: 256, elementLimit: 256))
            case "configureClassifierType":
                if data.keys.contains("applicablePlatformIDs") {
                    throw WebBridgeInputError.fixedPlatforms
                }
                configureClassifierType(
                    typeID: try webString(data, key: "typeID", limit: 256),
                    name: try webString(data, key: "name", limit: ClassifierTypeAsset.maximumNameLength)
                )
            case "confirmDeleteClassifierType":
                deleteClassifierType(typeID: try webString(data, key: "typeID", limit: 256))
            case "createProviderProfile":
                createProviderProfile(typeRaw: try webString(data, key: "type", limit: 32))
            case "testProviderProfile":
                testProviderProfile(
                    profileID: try webString(data, key: "profileID", limit: 128),
                    rawCredential: try webOptionalString(data, key: "credential", limit: ProviderCredentialRecord.maximumCharacters),
                    customEndpoint: try webOptionalString(data, key: "customEndpoint", limit: APIKeyProviderProfile.maximumEndpointLength),
                    testModelIdentifier: try webOptionalString(data, key: "testModelIdentifier", limit: APIKeyProviderProfile.maximumTestModelIdentifierLength),
                    protocolConfiguration: try webProviderConfiguration(data)
                )
            case "updateProviderConnection":
                updateProviderConnection(
                    profileID: try webString(data, key: "profileID", limit: 128),
                    rawCredential: try webOptionalString(data, key: "credential", limit: ProviderCredentialRecord.maximumCharacters),
                    customEndpoint: try webOptionalString(data, key: "customEndpoint", limit: APIKeyProviderProfile.maximumEndpointLength),
                    testModelIdentifier: try webOptionalString(data, key: "testModelIdentifier", limit: APIKeyProviderProfile.maximumTestModelIdentifierLength),
                    protocolConfiguration: try webProviderConfiguration(data)
                )
            case "probeProviderModelCatalog":
                probeProviderModelCatalog(profileID: try webString(data, key: "profileID", limit: 128))
            case "confirmDeleteProviderProfile":
                deleteProviderProfile(profileID: try webString(data, key: "profileID", limit: 128))
            case "rearrangeTree":
                rearrangeTree(treeID: try webString(data, key: "treeID", limit: 256))
            case "addTag":
                addTag(
                    treeID: try webString(data, key: "treeID", limit: 256),
                    name: try webString(data, key: "name", limit: 128),
                    description: try webOptionalString(data, key: "description", limit: TagTreeNode.maximumDescriptionLength),
                    parentID: try webOptionalString(data, key: "parentID", limit: 256),
                    positionX: try webCanvasCoordinate(data, key: "positionX"),
                    positionY: try webCanvasCoordinate(data, key: "positionY")
                )
            case "moveTag":
                moveTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256), positionX: try webCanvasCoordinate(data, key: "positionX"), positionY: try webCanvasCoordinate(data, key: "positionY"))
            case "renameTag":
                renameTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256), name: try webString(data, key: "name", limit: 128))
            case "updateTag":
                updateTag(
                    treeID: try webString(data, key: "treeID", limit: 256),
                    nodeID: try webString(data, key: "nodeID", limit: 256),
                    name: try webString(data, key: "name", limit: 128),
                    description: try webOptionalString(data, key: "description", limit: TagTreeNode.maximumDescriptionLength)
                )
            case "connectTag":
                connectTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256), parentID: try webString(data, key: "parentID", limit: 256))
            case "disconnectTag":
                disconnectTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256))
            case "deleteTag":
                deleteTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256))
            case "saveClassificationSettings":
                saveClassificationSettings(enabled: try webBool(data, key: "classificationEnabled"))
            case "connectChatGPT": connectChatGPT()
            case "openChatGPTUsage": try Self.openChatGPTURL(URL(string: "https://chatgpt.com/settings/usage")!)
            case "acknowledgeChatGPTPlan":
                Task { [weak self] in
                    do { try await self?.chatGPTClient?.acknowledgePlanUsage(); await self?.refreshChatGPTStatus() }
                    catch { self?.issue = error.localizedDescription; self?.onWebStateChange?() }
                }
            case "cancelChatGPTSignIn":
                Task { await chatGPTClient?.cancelSignIn() }
            case "disconnectChatGPT": disconnectChatGPT()
            case "refreshChatGPTModels": refreshChatGPTModels()
            case "retryChatGPTClassifications": retryChatGPTClassifications()
            case "saveChatGPTUsageLimit":
                let raw = try webOptionalString(data, key: "dailyRequestLimit", limit: 12)
                guard raw == nil || Int(raw!) != nil else { throw WebBridgeInputError.invalidChoice("daily request limit") }
                try saveChatGPTUsageLimit(raw.flatMap(Int.init))
            case "saveClassificationProvider":
                guard let effort = ClassificationReasoningEffort(rawValue: try webString(data, key: "reasoningEffort", limit: 32)) else { throw WebBridgeInputError.invalidChoice("reasoning effort") }
                try saveClassificationProvider(typeID: webString(data, key: "typeID", limit: 256),
                    providerModel: webString(data, key: "providerModel", limit: 520), reasoningEffort: effort)
            case "setClassifierTypePaused":
                setClassifierTypePaused(typeID: try webString(data, key: "typeID", limit: 256), paused: try webBool(data, key: "paused"))
            case "saveClassifierTypeTagging":
                let input = try Self.parseClassifierTypeTaggingWebInput(data)
                saveClassifierTypeTagging(typeID: input.typeID, settings: input.settings)
            case "setBackupOwnerCode":
                backupOwnerCode = try webString(data, key: "ownerCode", limit: 512)
                setBackupOwnerCode()
            case "unlockBackup":
                backupOwnerCode = try webString(data, key: "ownerCode", limit: 512)
                unlockBackupMode()
            case "saveBackup":
                backupDirectory = try webString(data, key: "directory", limit: 2_048)
                backupEnabled = try webBool(data, key: "enabled")
                saveBackupConfiguration()
            case "backupNow":
                backupClassifierNow()
            default:
                throw WebBridgeInputError.invalidChoice("action")
            }
        } catch {
            issue = error.localizedDescription
        }
        return true
    }

    func webString(_ data: [String: Any], key: String, limit: Int) throws -> String {
        guard let value = data[key] as? String else { throw WebBridgeInputError.missingValue(key) }
        guard value.count <= limit else { throw WebBridgeInputError.exceedsLimit(key, limit) }
        return value
    }

    func webOptionalString(_ data: [String: Any], key: String, limit: Int) throws -> String? {
        guard let value = data[key] as? String else { return nil }
        guard value.count <= limit else { throw WebBridgeInputError.exceedsLimit(key, limit) }
        return value
    }

    func webStringArray(_ data: [String: Any], key: String, limit: Int, elementLimit: Int) throws -> [String] {
        guard let raw = data[key] as? [Any] else { throw WebBridgeInputError.missingValue(key) }
        guard raw.count <= limit else { throw WebBridgeInputError.exceedsLimit(key, limit) }
        let values = try raw.map { value -> String in
            guard let string = value as? String, !string.isEmpty, string.count <= elementLimit else {
                throw WebBridgeInputError.invalidChoice(key)
            }
            return string
        }
        guard Set(values).count == values.count else { throw WebBridgeInputError.invalidChoice(key) }
        return values
    }

    func webProviderConfiguration(_ data: [String: Any]) throws -> [String: String]? {
        guard let raw = data["protocolConfiguration"] as? [String: Any] else { return nil }
        guard raw.count <= ProviderConfigurationField.allCases.count else {
            throw WebBridgeInputError.exceedsLimit("protocol configuration", ProviderConfigurationField.allCases.count)
        }
        return try Dictionary(uniqueKeysWithValues: raw.map { key, value in
            guard ProviderConfigurationField(rawValue: key) != nil,
                  let string = value as? String,
                  string.count <= 512 else {
                throw WebBridgeInputError.invalidChoice("protocol configuration")
            }
            return (key, string)
        })
    }

    func webCanvasCoordinate(_ data: [String: Any], key: String) throws -> Double {
        guard let value = data[key] as? NSNumber else { throw WebBridgeInputError.missingValue(key) }
        let coordinate = value.doubleValue
        guard coordinate.isFinite, (0...20_000).contains(coordinate) else {
            throw WebBridgeInputError.invalidChoice("canvas coordinate")
        }
        return coordinate
    }

    func webBool(_ data: [String: Any], key: String) throws -> Bool {
        guard let value = data[key] as? Bool else { throw WebBridgeInputError.missingValue(key) }
        return value
    }
}
