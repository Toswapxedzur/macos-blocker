import FamilyControls
import MacBlockerCore
import MacBlockerScreenTime
import SwiftUI

/// Lets the user pick the apps/categories/domains to manage, persists their
/// opaque tokens into the App Group token store, assigns the resulting
/// `BlockTarget`s to a chosen block group, and rebuilds the enforcement plan.
struct ScreenTimeSelectionView: View {
    @State private var selection = FamilyActivitySelection()
    @State private var isPickerPresented = false
    @State private var authorized = ScreenTimeAuthorization.isAuthorized
    @State private var groups: [BlockGroup] = []
    @State private var selectedGroupID: String = ""
    @State private var statusText: String?
    @State private var errorText: String?

    private let tokenStore = ScreenTimeTokenStore()
    private let sharedStore = SharedAppGroupStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Screen Time Targets")
                .font(.title2.bold())

            if !authorized {
                Button("Authorize Screen Time") {
                    Task { await authorize() }
                }
            }

            Button("Choose Apps, Categories, and Domains") {
                isPickerPresented = true
            }
            .disabled(!authorized)
            .familyActivityPicker(isPresented: $isPickerPresented, selection: $selection)

            Text("Applications: \(selection.applicationTokens.count)")
            Text("Categories: \(selection.categoryTokens.count)")
            Text("Web domains: \(selection.webDomainTokens.count)")

            if groups.isEmpty {
                Text("No groups yet. Create one in the Editor tab first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Assign to group", selection: $selectedGroupID) {
                    ForEach(groups) { group in
                        Text(group.name).tag(group.id)
                    }
                }

                Button("Assign Targets to Group") {
                    assignSelection()
                }
                .disabled(selectedGroupID.isEmpty || selection == FamilyActivitySelection())
            }

            if let statusText {
                Text(statusText).font(.footnote).foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
        .onAppear(perform: reloadGroups)
    }

    private func authorize() async {
        do {
            authorized = try await ScreenTimeAuthorization.requestIndividual()
        } catch {
            errorText = String(describing: error)
        }
    }

    private func reloadGroups() {
        guard let data = sharedStore.readData(SharedAppGroupStore.webStoreFileName),
              let result = try? ChromeExtensionImporter.importGroups(from: data) else {
            groups = []
            return
        }
        groups = result.groups
        if selectedGroupID.isEmpty {
            selectedGroupID = groups.first?.id ?? ""
        }
    }

    private func assignSelection() {
        let result = tokenStore.makeTargets(from: selection)

        // Persist tokens (merge with any existing) and assign targets to group.
        var tokens = tokenStore.load()
        result.tokens.applications.forEach { tokens.applications[$0.key] = $0.value }
        result.tokens.categories.forEach { tokens.categories[$0.key] = $0.value }
        result.tokens.webDomains.forEach { tokens.webDomains[$0.key] = $0.value }
        tokenStore.save(tokens)

        sharedStore.setTargets(result.targets, forGroupID: selectedGroupID)
        rebuildPlan()
        statusText = "Assigned \(result.targets.count) targets to \(groupName(selectedGroupID))."
    }

    private func rebuildPlan() {
        guard let data = sharedStore.readData(SharedAppGroupStore.webStoreFileName),
              let result = try? ChromeExtensionImporter.importGroups(from: data) else {
            return
        }
        let plan = EnforcementPlanBuilder.build(
            from: result.groups,
            nativeTargetsByGroup: sharedStore.loadGroupTargets()
        )
        sharedStore.saveEnforcementPlan(plan)
        ScreenTimeScheduler.sync(with: plan)
    }

    private func groupName(_ id: String) -> String {
        groups.first(where: { $0.id == id })?.name ?? id
    }
}
