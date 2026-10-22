import SwiftUI

/// DashboardView is the skill list page (F02)
///
/// Displays all installed skills, supporting search, filtering, and sorting
struct DashboardView: View {

    /// @Bindable allows @Observable object properties to be prefixed with $ to create Binding
    /// For example, $viewModel.searchText creates a Binding<String>
    @Bindable var viewModel: DashboardViewModel
    @Binding var selectedSkillID: String?
    @Environment(SkillManager.self) private var skillManager

    @AppStorage(LanguageSettings.appLanguageKey) private var appLanguageRaw: String = LanguageSettings.defaultLanguage.rawValue

    @Environment(\.localizationBundle) private var localizationBundle
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if skillManager.isLoading && skillManager.skills.isEmpty {
                // Show progress indicator on first load
                ProgressView("Scanning skills...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredSkills.isEmpty {
                // Empty state
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No Skills Found",
                    subtitle: viewModel.searchText.isEmpty
                        ? "Install skills using npx skills add or the CLI"
                        : "No skills match your search"
                )
            } else {
                // Skill list
                List(viewModel.filteredSkills, selection: $selectedSkillID) { skill in
                    SkillRowView(
                        skill: skill,
                        usageSummary: viewModel.usageSummary(for: skill),
                        showsUnknownUsage: viewModel.sortOrder == .usage,
                        usageIsScanning: viewModel.isRelevantUsagePending,
                        unknownUsageHelpKey: viewModel.unknownUsageHelpKey
                    )
                        .tag(skill.id)
                        // contextMenu is macOS's right-click menu
                        .contextMenu {
                            Button("Open in Finder") {
                                NSWorkspace.shared.selectFile(
                                    nil,
                                    inFileViewerRootedAtPath: skill.canonicalURL.path
                                )
                            }
                            Divider()  // Menu separator
                            Button("Delete", role: .destructive) {
                                viewModel.requestDelete(skill: skill)
                            }
                        }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle(navigationTitle)
        // Search bar (macOS standard search field, displayed in toolbar)
        .searchable(text: $viewModel.searchText, prompt: "Search skills...")
        // Toolbar: sorting and filtering
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        appLanguageRaw = AppLanguage.system.rawValue
                    } label: {
                        LText(key: L10nKeys.settingsLanguageSystemDefault)
                    }

                    Button {
                        appLanguageRaw = AppLanguage.english.rawValue
                    } label: {
                        LText(key: L10nKeys.settingsLanguageEnglish)
                    }

                    Button {
                        appLanguageRaw = AppLanguage.simplifiedChinese.rawValue
                    } label: {
                        LText(key: L10nKeys.settingsLanguageChineseHans)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                        Text(languageBadge)
                            .appFont(.caption2)
                            .monospaced()
                    }
                }
                .help(L10n.string(L10nKeys.dashboardLanguageMenuHelp, bundle: localizationBundle, locale: locale))
            }

            // placement: .navigation places toolbar items on the left (navigation area), default .automatic places on right
            ToolbarItemGroup(placement: .navigation) {
                Menu {
                    // Section creates titled groups in menus, similar to Android's menu group
                    Section("Sort By") {
                        ForEach(DashboardViewModel.SortOrder.allCases, id: \.self) { order in
                            Button {
                                if viewModel.sortOrder == order {
                                    // Click selected sort field → toggle ascending/descending
                                    viewModel.sortDirection = viewModel.sortDirection.toggled
                                } else {
                                    // Click new sort field → switch to that field and use its default direction
                                    viewModel.sortOrder = order
                                    viewModel.sortDirection = order.defaultDirection
                                }
                            } label: {
                                // HStack horizontal layout: icon + text + sort direction arrow
                                HStack {
                                    Label(order.rawValue, systemImage: order.iconName)
                                    if viewModel.sortOrder == order {
                                        // Spacer pushes arrow to the right
                                        Spacer()
                                        Image(systemName: viewModel.sortDirection.iconName)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    // Toolbar button appearance: sort icon + current sort field + direction arrow
                    // Label provides both text and icon, macOS toolbar decides which to display based on space
                    HStack(spacing: 2) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(viewModel.sortOrder.rawValue)
                        Image(systemName: viewModel.sortDirection.iconName).appFont(.caption2)
                            // imageScale controls SF Symbol size
                            .imageScale(.small)
                    }
                }

                if viewModel.sortOrder == .usage {
                    if viewModel.isRelevantUsagePending {
                        ProgressView()
                            .controlSize(.small)
                            .help(L10n.string(L10nKeys.usageScanning, bundle: localizationBundle, locale: locale))
                    } else if viewModel.relevantUsageFailedLogCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(L10n.string(L10nKeys.usageIncompleteHelp, bundle: localizationBundle, locale: locale))
                    }
                }
            }
        }
        // Delete confirmation dialog
        // .alert similar to Android's AlertDialog or Web's confirm()
        .alert("Delete Skill", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelDelete()
            }
            Button("Delete", role: .destructive) {
                Task { await viewModel.confirmDelete() }
            }
        } message: {
            if let skill = viewModel.skillToDelete {
                Text("Are you sure you want to delete \"\(skill.displayName)\"? This will remove the skill directory and all symlinks. This action cannot be undone.")
            }
        }
        // Error message
        .overlay(alignment: .bottom) {
            if let error = skillManager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                    Spacer()
                    Button("Dismiss") {
                        skillManager.errorMessage = nil
                    }
                    .buttonStyle(.borderless)
                }
                .padding()
                .background(.red.opacity(0.1))
                .cornerRadius(8)
                .padding()
            }
        }
        // Usage sorting is lazy: scan only when the user actually asks for it, and only the
        // Agents contributing to the current scope. Re-check on filter changes so switching
        // back to "all" still scans Agents that have not been touched yet.
        .onChange(of: viewModel.sortOrder) { _, newOrder in
            guard newOrder == .usage else { return }
            scanRelevantUsageIfNeeded()
        }
        .onChange(of: viewModel.selectedAgentFilter) { _, _ in
            guard viewModel.sortOrder == .usage else { return }
            scanRelevantUsageIfNeeded()
        }
    }

    private func scanRelevantUsageIfNeeded() {
        guard viewModel.hasUnscannedRelevantUsage else { return }
        Task {
            await skillManager.loadSkillUsage(
                agentTypes: Set(viewModel.relevantUsageAgents)
            )
        }
    }

    private var navigationTitle: String {
        if let agent = viewModel.selectedAgentFilter {
            return agent.displayName
        }
        return "All Skills"
    }

    private var languageBadge: String {
        switch AppLanguage(storedRawValue: appLanguageRaw) {
        case .system:
            return "Auto"
        case .english:
            return "EN"
        case .simplifiedChinese:
            return "中"
        }
    }

}
