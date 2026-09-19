import Foundation
import VaultClassifierCore
import VaultClassifierBridge
import VaultClassifierLLM

// The local-hub request path: decoding browser operations, the per-video classification queue and in-flight de-duplication, resolved-tag broadcasts and source-icon caching.
// Split out of VaultClassifierApp.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour — pinned by ViewModelCharacterizationTests.
@MainActor
extension VaultClassifierViewModel {
    func handleSharedHubRequest(_ request: SharedHubClient.Request) -> SharedHubClient.Reply {
        handleSharedHubRequestBody(request)
    }

    func perfLog(_ message: @autoclosure () -> String) {
        guard Self.perfEnabled else { return }
        let collected = localState?.workspaceCatalog.datasets.reduce(0) { $0 + $1.collectedEntries.count } ?? -1
        VaultDevLog.shared.log("perf", message(), ["collected": "\(collected)"])
    }

    /// Structured native-side event into the unified dev log.
    func devLog(_ event: String, _ fields: [String: String] = [:]) {
        VaultDevLog.shared.log("native", event, fields)
    }

    func perfMS(_ start: DispatchTime, _ end: DispatchTime = DispatchTime.now()) -> String {
        String(format: "%.1f", Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    /// Maps display tag nodes to the wire tag shape, dropping any whose colors do
    /// not normalize. The response struct additionally gates on a valid theme
    /// pair; keeping this mapping shared means the single and batch paths emit
    /// identical tags.
    static func nativeVideoTags(from tags: [TagNode], confidenceByTagID: [String: Int] = [:]) -> [NativeVideoTag] {
        tags.compactMap { tag in
            guard let lightColorHex = TagColorAssignment.normalizedHex(tag.lightColorHex),
                  let darkColorHex = TagColorAssignment.normalizedHex(tag.darkColorHex) else {
                return nil
            }
            return NativeVideoTag(
                id: tag.id,
                name: tag.name,
                lightColorHex: lightColorHex,
                darkColorHex: darkColorHex,
                confidence: confidenceByTagID[tag.id] ?? 0
            )
        }
    }

    /// Shorthand: map a projection to wire tags carrying their confidence.
    static func nativeVideoTags(from projection: VideoTagsProjection) -> [NativeVideoTag] {
        nativeVideoTags(from: projection.tags, confidenceByTagID: projection.confidenceByTagID)
    }

    static func inFlightKey(_ platformID: String, _ entryID: String) -> String {
        "\(platformID)\u{1F}\(entryID)"
    }

    func queueVideoClassification(platformID: String, items: [NativeVideoTagsBatchItem]) {
        let fresh = items.filter {
            inFlightVideoClassifications.insert(Self.inFlightKey(platformID, $0.entryID)).inserted
        }
        guard !fresh.isEmpty else { return }
        // OCR the thumbnail as evidence only when a classifier type for this
        // platform opts in (default on). Local Vision OCR; the per-type gate that
        // decides whether a type actually consumes the text lives in classifyVideo.
        let ocrEnabled = coordinator?.ocrEvidencePlatformIDs().contains(platformID) ?? false
        // Fetch+OCR the whole batch's thumbnails concurrently up front (fetch is
        // network-bound) so they overlap each other and the serial LLM decodes;
        // the per-item recognizedText below then hits the warm cache / shared task.
        if ocrEnabled {
            let entries = fresh.map { (entryID: $0.entryID, thumbnailURL: $0.acceptedThumbnailURL(platformID: platformID)) }
            Task.detached { await ThumbnailOCR.shared.prewarm(platformID: platformID, entries: entries) }
        }
        Task { @MainActor [weak self] in
            // Classify a screenful at a time (LATENCY-REFINEMENT Phase 1): the engine
            // decodes a chunk's videos in ONE multi-sequence pass instead of one by
            // one, and each chunk's verdicts are pushed as soon as it lands. OCR for
            // the whole request was prewarmed above, so these awaits hit warm work.
            let chunkSize = Self.classificationChunkSize
            for start in stride(from: 0, to: fresh.count, by: chunkSize) {
                let chunk = Array(fresh[start..<min(start + chunkSize, fresh.count)])
                defer { for item in chunk { self?.inFlightVideoClassifications.remove(Self.inFlightKey(platformID, item.entryID)) } }
                guard let coordinator = self?.coordinator else { continue }
                var inputs: [VideoClassificationPipeline.Input] = []
                for item in chunk {
                    let thumbnailText = ocrEnabled
                        ? await ThumbnailOCR.shared.recognizedText(platformID: platformID, entryID: item.entryID, thumbnailURL: item.acceptedThumbnailURL(platformID: platformID))
                        : nil
                    inputs.append(.init(
                        title: item.title, summary: item.summary, text: thumbnailText ?? item.text,
                        entryID: item.entryID, creatorID: item.creatorID))
                }
                var projections = (try? await coordinator.classifyVideos(platformID: platformID, items: inputs)) ?? [:]
                if projections.isEmpty {
                    // The batch failed as a whole — fall back to one video at a time
                    // so a single bad item cannot sink the rest of the screen.
                    for input in inputs {
                        if let single = try? await coordinator.classifyVideo(
                            platformID: platformID, entryID: input.entryID, creatorID: input.creatorID,
                            title: input.title, summary: input.summary, text: input.text) {
                            projections[input.entryID] = single
                        }
                    }
                }
                for item in chunk {
                    guard let projection = projections[item.entryID] else { continue }
                    self?.broadcastResolvedVideoTags(platformID: platformID, entryID: item.entryID, projection: projection)
                }
            }
            self?.onWebStateChange?()
        }
    }

    func broadcastResolvedVideoTags(platformID: String, entryID: String, projection: VideoTagsProjection) {
        // The classifier only tags — it makes no block decision. The verdict is
        // the extension's job (its custom-rule engine reads these tags). So the
        // broadcast carries tags + confidence only; feed/page default to allow.
        let broadcast = NativeVideoTagsBroadcast(platformID: platformID, items: [NativeVideoTagsBatchResponseItem(
            entryID: entryID, tags: Self.nativeVideoTags(from: projection),
            predicted: projection.predicted, pending: false)])
        guard let encoded = try? JSONEncoder().encode(broadcast),
              let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return }
        sharedHubClient?.broadcast(operation: SharedBrowserBridgeOperation.videoTagsUpdatedBroadcast, body: object)
        devLog("video-tags-updated", ["platform": platformID, "entry": entryID, "tags": "\(projection.tags.count)"])
    }

    static func creatorEchoTag(creatorID: String) -> NativeVideoTag {
        // "youtube:handle:@name" → "@name"; fall back to the whole identifier.
        let name = creatorID.split(separator: ":").last.map(String.init) ?? creatorID
        return NativeVideoTag(
            id: "vault:test:\(name)",
            name: name,
            lightColorHex: Self.creatorEchoColors.light,
            darkColorHex: Self.creatorEchoColors.dark
        )
    }

    func handleSharedHubRequestBody(_ request: SharedHubClient.Request) -> SharedHubClient.Reply {
        do {
            guard let coordinator else { return .failure("classifier-unavailable") }
            if request.operation != .collect && request.operation != .diagnostic {
                devLog("hub-op", ["op": request.operation.rawValue])
            }
            switch request.operation {
            case .bridgeInfo:
                _ = try JSONDecoder().decode(NativeBridgeInfoRequest.self, from: request.bodyData)
                return try sharedHubReply(NativeBridgeInfoResponse())
            case .collectionInfo:
                _ = try JSONDecoder().decode(NativeCollectionInfoRequest.self, from: request.bodyData)
                let response = NativeCollectionInfoResponse(enabledPlatformIDs: coordinator.enabledCollectionPlatformIDs(), developmentMode: VaultDevLog.shared.isEnabled, ocrPlatformIDs: coordinator.ocrEvidencePlatformIDs())
                collectionDiagnostics?.record(event: "collection-info-served", outcome: response.enabledPlatformIDs.isEmpty ? "disabled" : "enabled")
                return try sharedHubReply(response)
            case .diagnostic:
                let diagnostic = try JSONDecoder().decode(NativeCollectionDiagnosticRequest.self, from: request.bodyData)
                try diagnostic.validate()
                collectionDiagnostics?.record(
                    platformID: diagnostic.platformID,
                    event: diagnostic.event.rawValue,
                    detail: diagnostic.detail?.rawValue,
                    outcome: "received"
                )
                // Diagnostics are recorded to the local log, not the web
                // snapshot; pushing here would re-render the whole UI with an
                // unchanged payload.
                return try sharedHubReply(NativeCollectionDiagnosticResponse(accepted: true))
            case .collect:
                let request = try JSONDecoder().decode(NativeCollectionRequest.self, from: request.bodyData)
                collectionDiagnostics?.record(platformID: request.entry.platform, event: "collection-received", outcome: "received")
                let tStore = DispatchTime.now()
                let inserted = try coordinator.collectPlatformEntry(
                    request.entry,
                    firstObservedAtMilliseconds: request.firstObservedAtMilliseconds,
                    lastObservedAtMilliseconds: request.lastObservedAtMilliseconds,
                    observationCount: request.observationCount
                )
                cacheSourceIcon(from: request.entry)
                collectionDiagnostics?.record(platformID: request.entry.platform, event: "collection-stored", outcome: inserted ? "inserted" : "duplicate")
                // Browser collection bypasses WebKit actions, so publish the
                // freshly persisted catalog to the already-open app now.
                let tSnapshot = DispatchTime.now()
                refreshLocalState()
                let tPush = DispatchTime.now()
                onWebStateChange?()
                let tEnd = DispatchTime.now()
                perfLog("collect store=\(perfMS(tStore, tSnapshot)) snapshot=\(perfMS(tSnapshot, tPush)) push=\(perfMS(tPush, tEnd)) total=\(perfMS(tStore, tEnd))ms")
                return try sharedHubReply(NativeCollectionResponse(accepted: true, inserted: inserted))
            case .videoTags:
                let videoTags = try JSONDecoder().decode(NativeVideoTagsRequest.self, from: request.bodyData)
                try videoTags.validate()
                if Self.creatorEchoTestMode {
                    devLog("video-tags", ["platform": videoTags.platformID, "entry": videoTags.entryID, "outcome": "creator-echo"])
                    return try sharedHubReply(NativeVideoTagsResponse(
                        platformID: videoTags.platformID, entryID: videoTags.entryID,
                        tags: [Self.creatorEchoTag(creatorID: videoTags.creatorID)], predicted: false, pending: false))
                }
                if let cached = coordinator.cachedVideoTags(platformID: videoTags.platformID, entryID: videoTags.entryID) {
                    devLog("video-tags", ["platform": videoTags.platformID, "entry": videoTags.entryID, "outcome": "cached", "tags": "\(cached.tags.count)"])
                    return try sharedHubReply(NativeVideoTagsResponse(
                        platformID: videoTags.platformID, entryID: videoTags.entryID,
                        tags: Self.nativeVideoTags(from: cached), predicted: cached.predicted, pending: false))
                }
                // No classifier type targets this platform → definitively empty, not
                // pending (avoids a stuck "Tagging" pill that re-requests forever).
                guard coordinator.hasClassifierTypes(platformID: videoTags.platformID) else {
                    devLog("video-tags", ["platform": videoTags.platformID, "entry": videoTags.entryID, "outcome": "empty-no-types"])
                    return try sharedHubReply(NativeVideoTagsResponse(
                        platformID: videoTags.platformID, entryID: videoTags.entryID, tags: [], predicted: false, pending: false))
                }
                devLog("video-tags", ["platform": videoTags.platformID, "entry": videoTags.entryID, "outcome": "queued-pending"])
                // Not classified yet: queue background classification and report
                // pending. The completed result is pushed to the browsers over the
                // hub, so the pill resolves without polling.
                queueVideoClassification(platformID: videoTags.platformID, items: [NativeVideoTagsBatchItem(
                    entryID: videoTags.entryID, creatorID: videoTags.creatorID,
                    title: videoTags.title, summary: videoTags.summary, text: videoTags.text)])
                return try sharedHubReply(NativeVideoTagsResponse(
                    platformID: videoTags.platformID, entryID: videoTags.entryID, tags: [], predicted: false, pending: true))
            case .videoTagsBatch:
                let batch = try JSONDecoder().decode(NativeVideoTagsBatchRequest.self, from: request.bodyData)
                try batch.validate()
                if Self.creatorEchoTestMode {
                    devLog("video-tags-batch", ["platform": batch.platformID, "items": "\(batch.items.count)", "outcome": "creator-echo"])
                    return try sharedHubReply(NativeVideoTagsBatchResponse(
                        platformID: batch.platformID,
                        items: batch.items.map { item in
                            NativeVideoTagsBatchResponseItem(
                                entryID: item.entryID,
                                tags: [Self.creatorEchoTag(creatorID: item.creatorID)],
                                predicted: false, pending: false)
                        }))
                }
                let platformHasTypes = coordinator.hasClassifierTypes(platformID: batch.platformID)
                var responses: [NativeVideoTagsBatchResponseItem] = []
                var pendingItems: [NativeVideoTagsBatchItem] = []
                var cachedCount = 0
                for item in batch.items {
                    if let cached = coordinator.cachedVideoTags(platformID: batch.platformID, entryID: item.entryID) {
                        cachedCount += 1
                        responses.append(NativeVideoTagsBatchResponseItem(
                            entryID: item.entryID, tags: Self.nativeVideoTags(from: cached), predicted: cached.predicted, pending: false))
                    } else if !platformHasTypes {
                        // No classifier type for this platform → definitively empty.
                        responses.append(NativeVideoTagsBatchResponseItem(entryID: item.entryID, tags: [], predicted: false, pending: false))
                    } else {
                        responses.append(NativeVideoTagsBatchResponseItem(entryID: item.entryID, tags: [], predicted: false, pending: true))
                        pendingItems.append(item)
                    }
                }
                devLog("video-tags-batch", ["platform": batch.platformID, "items": "\(batch.items.count)", "cached": "\(cachedCount)", "pending": "\(pendingItems.count)", "hasTypes": platformHasTypes ? "1" : "0"])
                if !pendingItems.isEmpty {
                    queueVideoClassification(platformID: batch.platformID, items: pendingItems)
                }
                return try sharedHubReply(NativeVideoTagsBatchResponse(platformID: batch.platformID, items: responses))
            case .classifierTaxonomy:
                let taxonomyRequest = try JSONDecoder().decode(NativeClassifierTaxonomyRequest.self, from: request.bodyData)
                try taxonomyRequest.validate()
                let catalog = coordinator.snapshot().workspaceCatalog
                let types = catalog.classifierTypes
                    .filter { $0.applicablePlatformID == taxonomyRequest.platformID }
                    .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
                    .compactMap { type -> NativeClassifierTypeTaxonomy? in
                        guard let tree = catalog.trees.first(where: {
                            $0.id == type.treeID && $0.revision == type.treeRevision
                        }), let taxonomy = try? tree.inferenceTaxonomy() else { return nil }
                        let tagNodes = taxonomy.predictableLeafIDs
                            .compactMap { taxonomy.nodes[$0] }
                            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        let tags = NativeVideoTag.accepted(Self.nativeVideoTags(from: tagNodes))
                        guard !tags.isEmpty else { return nil }
                        return NativeClassifierTypeTaxonomy(typeID: type.id, name: type.name, tags: tags)
                    }
                return try sharedHubReply(NativeClassifierTaxonomyResponse(platformID: taxonomyRequest.platformID, types: types))
            case .submitCorrection:
                let correction = try JSONDecoder().decode(NativeSubmitCorrectionRequest.self, from: request.bodyData)
                try correction.validate()
                // The corrected set becomes authoritative; the reclassify callback
                // broadcasts the update to every connected browser's pill.
                let projection = try coordinator.submitCorrection(
                    classifierTypeID: correction.typeID,
                    platformID: correction.platformID,
                    entryID: correction.entryID,
                    correctTagIDs: correction.correctTagIDs
                )
                devLog("submit-correction", ["platform": correction.platformID, "entry": correction.entryID, "type": correction.typeID, "tags": "\(correction.correctTagIDs.count)"])
                refreshLocalState()
                onWebStateChange?()
                return try sharedHubReply(NativeSubmitCorrectionResponse(
                    platformID: correction.platformID, entryID: correction.entryID,
                    tags: Self.nativeVideoTags(from: projection.tags)))
            case .devLog:
                let entry = try JSONDecoder().decode(NativeDevLogRequest.self, from: request.bodyData)
                try entry.validate()
                VaultDevLog.shared.log(entry.layer, entry.event, entry.fields)
                return try sharedHubReply(NativeDevLogResponse(accepted: true))
            case .activityRecord, .activitySettings:
                // Activity ops belong to the hub host (Mac Vault owns the store),
                // never relayed to the classifier; reaching here means a misroute.
                return .failure("activity-not-handled-by-classifier")
            }
        } catch {
            collectionDiagnostics?.record(event: "request-rejected", outcome: "rejected")
            onWebStateChange?()
            return .failure(error.localizedDescription)
        }
    }

    func cacheSourceIcon(from entry: EntryEvidence) {
        guard case .string(let iconURL)? = entry.evidence.metadata["sourceIconURL"],
              SourceIconURLPolicy.isAccepted(platformID: entry.platform, value: iconURL) else {
            return
        }
        cacheSourceIcon(remoteURL: iconURL)
    }

    func cacheSourceIcon(remoteURL: String) {
        sourceIconCache?.cache(remoteURL: remoteURL) { [weak self] in
            Task { @MainActor in self?.onWebStateChange?() }
        }
    }

    func sharedHubReply<Body: Encodable>(_ body: Body) throws -> SharedHubClient.Reply {
        let encoded = try JSONEncoder().encode(body)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              SharedBrowserBridgeProtocol.isValidBody(object) else {
            return .failure("classifier-response-invalid")
        }
        return .success(object)
    }
}
