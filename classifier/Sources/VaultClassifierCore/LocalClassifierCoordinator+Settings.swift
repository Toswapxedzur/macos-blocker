import Foundation

// Settings, backup configuration, workspace catalog and knowledge-entry updates.
// Split out of LocalStore.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour.
extension LocalClassifierCoordinator {
    public func updateSettings(_ settings: ClassifierSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        state.settings = settings
        classificationMaximumTags = settings.localLLM.maximumTags
        let rules = settings.localLLM.houseRules.trimmingCharacters(in: .whitespacesAndNewlines)
        classificationHouseRules = rules.isEmpty ? nil : rules
        try stateFile.save(state)
    }

    public func updateLocalBackupConfiguration(_ configuration: LocalBackupConfiguration?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let configuration, configuration.isEnabled { _ = try configuration.directoryURL() }
        state.backupConfiguration = configuration
        try stateFile.save(state)
    }

    public func updateWorkspaceCatalog(_ catalog: WorkspaceCatalog) throws {
        lock.lock()
        defer { lock.unlock() }
        var reconciled = catalog
        reconciled.reconcileClassifierTypes()
        try reconciled.validate()
        state.workspaceCatalog = reconciled
        try stateFile.save(state)
    }

    /// Removes one knowledge entry (term or creator) by id. Deleting a creator
    /// description lets it be re-researched; deleting a term forgets it.
    public func deleteKnowledgeEntry(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        state.workspaceCatalog.knowledgeEntries.removeAll { $0.id == id }
        state.workspaceCatalog.creatorKnowledge.removeAll { $0.id == id }
        try stateFile.save(state)
    }

    /// Stores a term the user wrote themselves (Knowledge → add term). Returns
    /// false — storing nothing — when the subject is not a usable term (too short
    /// or too generic to match titles safely) or the description is empty; a term
    /// added WITHOUT a description goes through `researchTerm` instead.
    @discardableResult
    public func addKnowledgeTerm(subject: String, meaning: String) throws -> Bool {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KnowledgeEntry.isSpecificTermSubject(subject), !meaning.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        state.workspaceCatalog.upsertKnowledgeEntry(
            KnowledgeEntry(kind: .term, subject: subject, meaning: String(meaning.prefix(KnowledgeEntry.maximumMeaningLength))))
        try stateFile.save(state)
        return true
    }

    /// Edits the grounded description of an existing knowledge entry, keeping its
    /// kind, subject, id, and sources. A creator description edited here steers
    /// that creator's low-confidence classifications.
    @discardableResult
    public func updateKnowledgeEntryMeaning(id: String, meaning: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        func apply(_ entries: inout [KnowledgeEntry]) -> Bool {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            let existing = entries[index]
            entries[index] = KnowledgeEntry(
                kind: existing.kind,
                subject: existing.subject,
                meaning: trimmed,
                contextTagHints: existing.contextTagHints,
                sourceURLs: existing.sourceURLs,
                createdAtMilliseconds: existing.createdAtMilliseconds,
                updatedAtMilliseconds: WorkspaceCatalog.now()
            )
            return true
        }
        let changed = apply(&state.workspaceCatalog.knowledgeEntries)
            || apply(&state.workspaceCatalog.creatorKnowledge)
        if changed { try stateFile.save(state) }
        return changed
    }
}
