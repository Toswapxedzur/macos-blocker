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
            "packageUpdateMode": packageUpdateMode.rawValue,
            "localLLM": [
                    "speedQuality": llmSettings.speedQuality.rawValue,
                    "strictness": llmSettings.strictness.rawValue,
                    "houseRules": llmSettings.houseRules,
                    "modelFileName": llmSettings.modelFileName,
                    "systemRAMGB": HardwareProfile.physicalRAMGB(),
                    "engineStatus": llmEngineStatus,
                    "modelLibrary": Self.modelLibraryPayload(
                        availableModelFiles: availableModelFiles,
                        downloadFractions: modelDownloadFractions,
                        systemRAMGB: HardwareProfile.physicalRAMGB()
                    ),
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
                    "collectedCreators": webCollectedCreators(dataset.collectedEntries),
                ] as [String: Any]
            }
        let knowledgePayload: ([KnowledgeEntry]) -> [[String: Any]] = { entries in
            entries
                .sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
                .map { entry in
                    [
                        "id": entry.id,
                        "subject": entry.subject,
                        "meaning": entry.meaning,
                        "sourceURLs": entry.sourceURLs,
                        "updatedAtMilliseconds": entry.updatedAtMilliseconds,
                    ] as [String: Any]
                }
        }
        assets["knowledge"] = [
            "creators": knowledgePayload(catalog.creatorKnowledge),
            "terms": knowledgePayload(catalog.knowledgeEntries),
        ]
        assets["classifierTypes"] = catalog.classifierTypes.map { classifierType in
                [
                    "id": classifierType.id,
                    "name": classifierType.name,
                    "order": classifierType.order,
                    "treeID": classifierType.treeID,
                    "treeRevision": classifierType.treeRevision,
                    "datasetID": classifierType.datasetID,
                    "datasetRevision": classifierType.datasetRevision,
                    "applicablePlatformID": classifierType.applicablePlatformID ?? NSNull(),
                    // nil / absent = the type follows the global dials and rules.
                    "localModelOverrides": classifierType.localModelOverrides.map { overrides in
                        [
                            "houseRules": overrides.houseRules ?? NSNull(),
                            "speedQuality": overrides.speedQuality?.rawValue ?? NSNull(),
                            "strictness": overrides.strictness?.rawValue ?? NSNull(),
                        ] as [String: Any]
                    } ?? NSNull(),
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
                return ["id": binding.id, "name": binding.name, "browser": binding.browser, "treeID": binding.treeID, "datasetID": binding.datasetID, "activeClassifierTypeID": binding.activeClassifierTypeID ?? NSNull(), "collectionEnabled": binding.collectionEnabled, "sourceKind": definition?.sourceKind.rawValue ?? CollectionSourceKind.creator.rawValue, "supportsLocalModel": definition?.supportsLocalModel ?? false] as [String: Any]
            }
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
            "trash": catalog.trash.map { entry in
                [
                    "id": entry.id,
                    "kind": entry.kind.rawValue,
                    "name": entry.name,
                    "deletedAtMilliseconds": entry.deletedAtMilliseconds,
                ] as [String: Any]
            },
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
                // multi-megabyte state back across the bridge for navigation.
                return false
            case "createTree":
                createTree(name: try webString(data, key: "name", limit: 128))
            case "addCollectionPlatform":
                addCollectionPlatform(platformID: try webString(data, key: "platformID", limit: 64))
            case "confirmDeleteCollectionPlatform":
                deleteCollectionPlatform(platformID: try webString(data, key: "platformID", limit: 64))
            case "restoreTrashedEntry":
                restoreTrashedEntry(entryID: try webString(data, key: "id", limit: 64))
            case "permanentlyDeleteTrashedEntry":
                permanentlyDeleteTrashedEntry(entryID: try webString(data, key: "id", limit: 64))
            case "setCollectionEnabled":
                setCollectionEnabled(
                    platformID: try webString(data, key: "platformID", limit: 64),
                    enabled: try webBool(data, key: "enabled")
                )
            case "clearCollectionDiagnostics":
                clearCollectionDiagnostics()
            case "setActiveClassifierType":
                setActiveClassifierType(
                    platformID: try webString(data, key: "platformID", limit: 64),
                    classifierTypeID: try webOptionalString(data, key: "classifierTypeID", limit: 256)
                )
            case "createClassifierType":
                createClassifierType(
                    name: try webString(data, key: "name", limit: ClassifierTypeAsset.maximumNameLength),
                    platformID: try webString(data, key: "platformID", limit: 64)
                )
            case "reorderClassifierTypes":
                reorderClassifierTypes(orderedIDs: try webStringArray(data, key: "orderedIDs", limit: 256, elementLimit: 256))
            case "configureClassifierType":
                configureClassifierType(
                    typeID: try webString(data, key: "typeID", limit: 256),
                    name: try webString(data, key: "name", limit: ClassifierTypeAsset.maximumNameLength),
                    applicablePlatformID: try webString(data, key: "applicablePlatformID", limit: 64)
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
                confirmProviderProfileDeletion(profileID: try webString(data, key: "profileID", limit: 128))
            case "renameTree":
                renameTree(treeID: try webString(data, key: "treeID", limit: 256), name: try webString(data, key: "name", limit: 128))
            case "deleteTree":
                deleteTree(treeID: try webString(data, key: "treeID", limit: 256))
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
            case "savePackageSettings":
                let rawMode = try webString(data, key: "packageUpdateMode", limit: 32)
                guard let updateMode = PackageUpdateMode(rawValue: rawMode) else {
                    throw WebBridgeInputError.invalidChoice("package update mode")
                }
                packageUpdateMode = updateMode
                savePackageSettings()
            case "saveLocalLLMSettings":
                guard let speedQuality = SpeedQualityDial.resolve(try webString(data, key: "speedQuality", limit: 16)) else {
                    throw WebBridgeInputError.invalidChoice("speedQuality")
                }
                guard let strictness = StrictnessDial.resolve(Int(try webString(data, key: "strictness", limit: 4))) else {
                    throw WebBridgeInputError.invalidChoice("strictness")
                }
                saveLocalLLMSettings(LocalLLMSettings(
                    speedQuality: speedQuality,
                    strictness: strictness,
                    houseRules: try webString(data, key: "houseRules", limit: LocalLLMSettings.maximumHouseRulesLength)
                ))
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
            case "submitCorrection":
                submitCorrection(
                    classifierTypeID: try webString(data, key: "typeID", limit: 256),
                    platformID: try webString(data, key: "platformID", limit: 64),
                    entryID: try webString(data, key: "entryID", limit: 256),
                    correctTagIDs: try webStringArray(
                        data,
                        key: "correctTagIDs",
                        limit: CorrectionExample.maximumTagIDs,
                        elementLimit: 256
                    ),
                    note: try webOptionalString(data, key: "note", limit: CorrectionExample.maximumNoteLength)
                )
            case "saveClassifierTypeLocalModel":
                let input = try Self.parseClassifierTypeLocalModelWebInput(data)
                saveClassifierTypeLocalModel(typeID: input.typeID, overrides: input.overrides)
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

    /// The primary (creator-level) list carried in every snapshot: one row per
    /// (platform, creator) with only the fields the master lists and creator
    /// cards render. The heavy per-entry body is intentionally excluded and
    /// served lazily by `webCreatorEntriesPayload` when a creator is chosen, so
    /// the collected corpus never rides along on unrelated state updates.
    func webCollectedCreators(_ entries: [CollectedPlatformEntry]) -> [[String: Any]] {
        struct Aggregate {
            var platformID: String
            var creatorID: String
            var creatorName: String
            var entryCount: Int
            var firstObserved: Int64
            var lastObserved: Int64
            var iconURL: String?
            var subscriberCount: String?
            var latestObservedForFields: Int64
        }
        // Collapse a creator's observed identity forms (e.g. @handle + channel)
        // into one canonical row so the same creator never appears twice.
        let identityIndex = CreatorIdentityIndex(entries: entries)
        var order: [String] = []
        var groups: [String: Aggregate] = [:]
        for entry in entries {
            let canonicalCreatorID = identityIndex.canonical(of: entry.creatorID)
            let key = "\(entry.platformID)\u{1F}\(canonicalCreatorID)"
            let icon = entry.sourceIconURL.flatMap { sourceIconCache?.cachedURL(for: $0)?.absoluteString }
            let subscriber = entry.attributes["subscriberCount"]
            if var aggregate = groups[key] {
                aggregate.entryCount += 1
                aggregate.firstObserved = min(aggregate.firstObserved, entry.firstObservedAtMilliseconds)
                aggregate.lastObserved = max(aggregate.lastObserved, entry.lastObservedAtMilliseconds)
                // Display name/icon/subscriber follow the most recently observed
                // entry; an older observation only fills a still-missing icon.
                if entry.lastObservedAtMilliseconds >= aggregate.latestObservedForFields {
                    aggregate.latestObservedForFields = entry.lastObservedAtMilliseconds
                    aggregate.creatorName = entry.creatorName
                    if let icon { aggregate.iconURL = icon }
                    if let subscriber { aggregate.subscriberCount = subscriber }
                } else if aggregate.iconURL == nil, let icon {
                    aggregate.iconURL = icon
                }
                groups[key] = aggregate
            } else {
                order.append(key)
                groups[key] = Aggregate(
                    platformID: entry.platformID,
                    creatorID: canonicalCreatorID,
                    creatorName: entry.creatorName,
                    entryCount: 1,
                    firstObserved: entry.firstObservedAtMilliseconds,
                    lastObserved: entry.lastObservedAtMilliseconds,
                    iconURL: icon,
                    subscriberCount: subscriber,
                    latestObservedForFields: entry.lastObservedAtMilliseconds
                )
            }
        }
        return order.compactMap { key in
            guard let aggregate = groups[key] else { return nil }
            return [
                "platformID": aggregate.platformID,
                "creatorID": aggregate.creatorID,
                "creatorName": aggregate.creatorName,
                "entryCount": aggregate.entryCount,
                "firstObservedAtMilliseconds": aggregate.firstObserved,
                "lastObservedAtMilliseconds": aggregate.lastObserved,
                "cachedSourceIconURL": aggregate.iconURL ?? NSNull(),
                "subscriberCount": aggregate.subscriberCount ?? NSNull(),
            ]
        }
    }

    /// The full per-entry projection, delivered for one chosen creator only.
    func webCollectedEntry(_ entry: CollectedPlatformEntry, catalog: WorkspaceCatalog) -> [String: Any] {
        let correctionForms = catalog.classifierTypes
            .filter { $0.applicablePlatformID == entry.platformID }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
            .compactMap { type -> [String: Any]? in
                guard let tree = catalog.trees.first(where: {
                    $0.id == type.treeID && $0.revision == type.treeRevision
                }), let taxonomy = try? tree.inferenceTaxonomy() else { return nil }
                let correction = catalog.correctionExamples.first {
                    $0.classifierTypeID == type.id && $0.platformID == entry.platformID &&
                        $0.entryID == entry.entryID
                }
                let classification = catalog.videoClassification(
                    classifierTypeID: type.id,
                    platformID: entry.platformID,
                    entryID: entry.entryID
                )
                return [
                    "typeID": type.id,
                    "typeName": type.name,
                    "tagOptions": taxonomy.nodes.values
                        .filter(\.predictable)
                        .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
                        .map { ["id": $0.id, "name": $0.name] },
                    "correctTagIDs": correction?.correctTagIDs ?? classification?.tags.map(\.tagID) ?? [],
                    "note": correction?.note ?? "",
                    "corrected": correction != nil,
                ] as [String: Any]
            }
        return [
            "id": entry.id,
            "platformID": entry.platformID,
            "entryID": entry.entryID,
            "creatorID": entry.creatorID,
            "creatorName": entry.creatorName,
            "entryType": entry.entryType,
            "title": entry.title,
            "surface": entry.surface.rawValue,
            "text": entry.text ?? NSNull(),
            "summary": entry.summary ?? NSNull(),
            "suppliedTags": entry.suppliedTags,
            "canonicalURL": entry.canonicalURL ?? NSNull(),
            "attributes": entry.attributes,
            "cachedSourceIconURL": entry.sourceIconURL.flatMap {
                sourceIconCache?.cachedURL(for: $0)?.absoluteString
            } ?? NSNull(),
            "firstObservedAtMilliseconds": entry.firstObservedAtMilliseconds,
            "lastObservedAtMilliseconds": entry.lastObservedAtMilliseconds,
            "observationCount": entry.observationCount,
            "correctionForms": correctionForms,
        ]
    }

    /// Serves the full entries for one chosen creator, in response to a bounded
    /// `loadCreatorEntries` web action. Delivered on its own targeted channel so
    /// choosing a creator never re-pushes or re-renders the whole snapshot.
    func webCreatorEntriesPayload(datasetID: String, platformID: String, creatorID: String) -> [String: Any]? {
        let catalog = (localState ?? coordinator?.snapshot())?.workspaceCatalog
        guard let catalog,
              let dataset = catalog.datasets.first(where: { $0.id == datasetID }) else { return nil }
        // The selected creator is a canonical identity; return the entries of
        // every form in its class so a merged creator shows all its content.
        let identityClass = CreatorIdentityIndex(entries: dataset.collectedEntries).members(of: creatorID)
        let entries = dataset.collectedEntries
            .filter { $0.platformID == platformID && identityClass.contains($0.creatorID) }
            .map { webCollectedEntry($0, catalog: catalog) }
        return [
            "datasetID": datasetID,
            "platformID": platformID,
            "creatorID": creatorID,
            "entries": entries,
        ]
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
