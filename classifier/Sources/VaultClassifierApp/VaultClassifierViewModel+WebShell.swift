import Foundation
import VaultClassifierCore
import VaultClassifierResearch
import VaultClassifierBridge
import VaultClassifierLLM

// The untyped web-shell RPC: the state snapshot the WebView renders and the string-keyed action dispatcher, plus the web input coercion helpers.
// Split out of VaultClassifierApp.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour — pinned by ViewModelCharacterizationTests.
@MainActor
extension VaultClassifierViewModel {
    /// The WKWebView receives only the bounded local state necessary to render
    /// this development shell. Browser evidence, API keys, pairing material,
    /// stable identifiers stay in native storage.
    func webSnapshot() -> [String: Any] {
        let state = localState ?? coordinator?.snapshot()
        let backup = state?.backupConfiguration
        let notices: [String: Any] = [
            "backup": backupNotice ?? NSNull(),
            "knowledge": knowledgeNotice ?? NSNull(),
        ]
        let catalog = state?.workspaceCatalog ?? .starter()
        let researchSettings = state?.settings.research ?? ResearchSettings()
        let availableModelFiles = VaultLocalLLMEngine.availableModelFiles()
        let settingsPayload: [String: Any] = [
            "classificationEnabled": state?.settings.classificationEnabled ?? true,
            "packageUpdateMode": packageUpdateMode.rawValue,
            "localModels": [
                    "systemRAMGB": HardwareProfile.physicalRAMGB(),
                    "modelLibrary": Self.modelLibraryPayload(
                        availableModelFiles: availableModelFiles,
                        downloadFractions: modelDownloadFractions,
                        systemRAMGB: HardwareProfile.physicalRAMGB()
                    ).map { entry in
                        var payload = entry
                        let fileName = entry["ggufFileName"] as? String ?? ""
                        payload["engineStatus"] = availableModelFiles.contains(fileName)
                            ? (modelEngineStatuses[fileName] ?? "downloaded") : "no-model"
                        return payload
                    },
            ] as [String: Any],
            "research": [
                "enabled": researchSettings.enabled,
                "llmProviderProfileID": researchSettings.llmProviderProfileID ?? "",
                "llmModelIdentifier": researchSettings.llmModelIdentifier ?? "",
                "dailyTokenLimit": ResearchSettings.dailyTokenLimit,
                "tokensUsedToday": GroundedResearchQueue.usedResearchTokens(in: catalog.tokenUsage, at: Date()),
                "status": Self.researchStatusPayload(
                    queue: researchQueueStatus,
                    attempts: catalog.researchAttempts,
                    now: Date()
                ),
            ] as [String: Any],
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
        // Creators as the page shows them: name and icon from what the
        // classifier collected (by id or an alias of it), else from the id.
        // An exact id wins over an alias; a "name" that is only the id is none.
        // `icon` is the picture's web address, as collected.
        var creatorFaces: [String: (name: String?, icon: String?)] = [:]
        let collected = catalog.datasets.flatMap(\.collectedEntries)
        for aliasPass in [false, true] {
            for entry in collected {
                let name = entry.creatorName.isEmpty || entry.creatorName == entry.creatorID ? nil : entry.creatorName
                let icon = entry.sourceIconURL.flatMap {
                    SourceIconURLPolicy.isAccepted(platformID: entry.platformID, value: $0) ? $0 : nil
                }
                for id in aliasPass ? entry.sourceAliases : [entry.creatorID] {
                    let face = creatorFaces[id]
                    if aliasPass && face != nil { continue }
                    creatorFaces[id] = (face?.name ?? name, face?.icon ?? icon)
                }
            }
        }
        // A creator in Knowledge keeps its picture (owner 2026-09-30): copied
        // from the source-icon cache the first time it is there; a missing one
        // is asked for (a few per snapshot), for a later snapshot to keep.
        var picturesRequested = 0
        let picture: (String) -> String? = { [self] creatorID in
            guard let store = creatorPictures else { return nil }
            if let kept = store.url(for: creatorID) { return kept }
            guard let remote = creatorFaces[creatorID]?.icon else { return nil }
            if let jpeg = sourceIconJPEG(remoteURL: remote) {
                store.save(jpeg, for: creatorID)
                return store.url(for: creatorID)
            }
            if picturesRequested < 12 {
                picturesRequested += 1
                cacheSourceIcon(remoteURL: remote)
            }
            return nil
        }
        let knowledgePayload: ([KnowledgeEntry]) -> [[String: Any]] = { entries in
            entries
                .sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
                .map { entry in
                    var row: [String: Any] = [
                        "id": entry.id,
                        "subject": entry.subject,
                        "meaning": entry.meaning,
                        "writtenByUser": entry.writtenByUser,
                        "updatedAtMilliseconds": entry.updatedAtMilliseconds,
                    ]
                    if entry.kind == .creator {
                        let face = creatorFaces[entry.subject]
                        row["platformID"] = CreatorReference.platformID(of: entry.subject)
                        row["name"] = face?.name ?? CreatorReference.fallbackName(of: entry.subject)
                        row["icon"] = picture(entry.subject) ?? NSNull()
                    }
                    return row
                }
        }
        var knowledge: [String: Any] = [
            "creators": knowledgePayload(catalog.creatorKnowledge),
            "terms": knowledgePayload(catalog.knowledgeEntries),
        ]
        // "Add a creator" suggests creators the classifier has collected (only
        // while the Knowledge page is open: the list is long).
        if workspace == .knowledge {
            var seen = Set<String>()
            knowledge["knownCreators"] = catalog.datasets.flatMap(\.collectedEntries).compactMap { entry -> [String: String]? in
                guard !entry.creatorName.isEmpty, entry.creatorName != entry.creatorID,
                      CreatorReference.platforms.contains(entry.platformID),
                      seen.insert(entry.creatorID).inserted else { return nil }
                return ["platformID": entry.platformID, "id": entry.creatorID, "name": entry.creatorName]
            }
        }
        assets["knowledge"] = knowledge
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
                    "localModel": [
                        "houseRules": classifierType.localModel.houseRules,
                        "speedQuality": classifierType.localModel.speedQuality.rawValue,
                        "strictness": classifierType.localModel.strictness.rawValue,
                        "minimumTagsOverride": classifierType.localModel.minimumTagsOverride.map { $0 as Any } ?? NSNull(),
                        "maximumTagsOverride": classifierType.localModel.maximumTagsOverride.map { $0 as Any } ?? NSNull(),
                    ] as [String: Any],
                    // nil = follow the global research switch.
                    "researchEnabled": classifierType.researchEnabled ?? NSNull(),
                ] as [String: Any]
            }
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
        assets["providerRequestRecords"] = catalog.providerRequestRecords.map { record in
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
            }
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

    static func modelLibraryPayload(
        availableModelFiles: [String],
        downloadFractions: [String: Double],
        systemRAMGB: Int
    ) -> [[String: Any]] {
        let downloaded = Set(availableModelFiles)
        let recommendedID = LocalModelCatalog.recommended(systemRAMGB: systemRAMGB)?.id
        return LocalModelCatalog.curated
            .sorted { lhs, rhs in
                lhs.downloadSizeBytes == rhs.downloadSizeBytes
                    ? lhs.displayName < rhs.displayName
                    : lhs.downloadSizeBytes < rhs.downloadSizeBytes
            }
            .map { entry in
                let state: [String: Any]
                if let fraction = downloadFractions[entry.id] {
                    state = [
                        "kind": "downloading",
                        "fraction": min(1, max(0, fraction)),
                    ]
                } else if downloaded.contains(entry.ggufFileName) {
                    state = ["kind": "downloaded"]
                } else {
                    state = ["kind": "available"]
                }
                return [
                    "id": entry.id,
                    "displayName": entry.displayName,
                    "family": entry.family,
                    "paramsB": entry.paramsB,
                    "repo": entry.repo,
                    "ggufFileName": entry.ggufFileName,
                    "downloadSizeBytes": entry.downloadSizeBytes,
                    "minimumRAMGB": entry.minimumRAMGB,
                    "tier": entry.tier.rawValue,
                    "downloadURL": (try? entry.downloadURL.absoluteString) ?? "",
                    "recommended": entry.id == recommendedID,
                    "state": state,
                ] as [String: Any]
            }
    }

    /// The web renderer is a bundled local asset, but its messages are still
    /// treated as untrusted UI input. Keep the surface small and bounded so it
    /// cannot become another native IPC or provider-control path.
    /// Returns whether the web shell should publish a new snapshot.
    func performWebAction(_ action: String, data: [String: Any]) -> Bool {
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
                // except into Knowledge, whose creator suggestions ride along only
                // while it is open.
                return value == .knowledge
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
                renameTag(treeID: try webString(data, key: "treeID", limit: 256), nodeID: try webString(data, key: "nodeID", limit: 256), name: try webString(data, key: "name", limit: 128), refreshState: false)
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
            case "setClassifierTypePaused":
                setClassifierTypePaused(typeID: try webString(data, key: "typeID", limit: 256), paused: try webBool(data, key: "paused"))
            case "savePackageSettings":
                let rawMode = try webString(data, key: "packageUpdateMode", limit: 32)
                guard let updateMode = PackageUpdateMode(rawValue: rawMode) else {
                    throw WebBridgeInputError.invalidChoice("package update mode")
                }
                packageUpdateMode = updateMode
                savePackageSettings()
            case "downloadModel":
                downloadModel(id: try webString(data, key: "id", limit: 128))
            case "cancelModelDownload":
                cancelModelDownload(id: try webString(data, key: "id", limit: 128))
            case "deleteModelFile":
                deleteModelFile(fileName: try webString(data, key: "fileName", limit: 255))
            case "deleteKnowledgeEntry":
                deleteKnowledgeEntry(id: try webString(data, key: "id", limit: 512))
            case "addKnowledgeTerm":
                addKnowledgeTerm(
                    subject: try webString(data, key: "subject", limit: 120),
                    meaning: try webString(data, key: "meaning", limit: KnowledgeEntry.maximumMeaningLength)
                )
            case "addKnowledgeCreator":
                addKnowledgeCreator(
                    platformID: try webString(data, key: "platformID", limit: 64),
                    creator: try webString(data, key: "creator", limit: 512),
                    meaning: try webString(data, key: "meaning", limit: KnowledgeEntry.maximumMeaningLength)
                )
            case "editKnowledgeEntry":
                editKnowledgeEntry(
                    id: try webString(data, key: "id", limit: 512),
                    meaning: try webString(data, key: "meaning", limit: KnowledgeEntry.maximumMeaningLength)
                )
            case "retryFailedResearch":
                retryFailedResearch()
            case "saveResearchSettings":
                saveResearchSettings(ResearchSettings(
                    enabled: try webBool(data, key: "enabled"),
                    llmProviderProfileID: try webOptionalString(data, key: "llmProviderProfileID", limit: 256),
                    llmModelIdentifier: try webOptionalString(data, key: "llmModelIdentifier", limit: 256)
                ))
            case "saveClassifierTypeLocalModel":
                let input = try Self.parseClassifierTypeLocalModelWebInput(data)
                saveClassifierTypeLocalModel(typeID: input.typeID, settings: input.settings)
            case "saveClassifierTypeResearch":
                let input = try Self.parseClassifierTypeResearchWebInput(data)
                saveClassifierTypeResearch(typeID: input.typeID, researchEnabled: input.researchEnabled)
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
                backupLocalModelNow()
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
