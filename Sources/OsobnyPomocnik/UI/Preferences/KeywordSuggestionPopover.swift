import SwiftUI

/// Floats off the "sparkles" button on the keywords field. Analyzes recent history, shows
/// checkbox suggestions, and — only on explicit "Pridať vybrané" — appends the checked ones to
/// the real keyword fields. Never touches existing keywords: see KeywordSuggestionEngine's
/// prompt-level guard and this view's append-only write below.
struct KeywordSuggestionPopover: View {
    // Both are @Observable singletons (same pattern as PreferencesView's own @State dictation/
    // profileStore) — referenced directly rather than threaded through init, since this view
    // has no separate ownership story for them.
    private let dictation = DictationEngine.shared
    private let profileStore = AppProfileStore.shared
    /// Closes the popover from the caller's `.popover(isPresented:)`.
    @Binding var isPresented: Bool

    // The memberwise init Swift would synthesize here is `private` (it takes its access level
    // from the least-visible stored property, and `dictation`/`profileStore` above are private)
    // — so DictationTab's `KeywordSuggestionPopover(isPresented:)` needs this explicit one.
    init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    // Not named "State" — that shadows SwiftUI's own @State property wrapper and breaks it.
    private enum LoadState {
        case loading
        case failed(String)
        case loaded([KeywordSuggestion])
    }
    @State private var state: LoadState = .loading
    @State private var checked: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            if case .loaded(let suggestions) = state, !suggestions.isEmpty {
                Divider()
                footer(suggestions)
            }
        }
        // A sheet (not popover, see DictationTab) gets an explicit size instead of squeezing
        // to fit its content. Sized PER STATE, not one fixed box for everything: a spinner and
        // a short sentence don't need 640pt of height — that just reads as a bug (huge empty
        // sheet). Compact while there's nothing to browse, then grows once there's a real list.
        .frame(width: sheetSize.width, height: sheetSize.height)
        .animation(.easeInOut(duration: 0.2), value: sheetSize.height)
        .task { await load() }
    }

    private var sheetSize: (width: CGFloat, height: CGFloat) {
        switch state {
        case .loading, .failed:                     (420, 220)
        case .loaded(let s) where s.isEmpty:         (420, 200)
        case .loaded:                                (560, 620)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Návrhy kľúčových slov").font(Theme.bodyBold(13))
            Text("Tvoje existujúce kľúčové slová sa nemenia — pridá sa len to, čo odškrtneš nižšie.")
                .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Analyzujem históriu diktovaní… (gpt-4o-mini, ~0,01 €)")
                    .font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity).padding(24)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                Button("Skúsiť znova") { Task { await load() } }
            }
            .padding(14)

        case .loaded(let suggestions) where suggestions.isEmpty:
            Text("Nenašiel som nič nové — tvoje kľúčové slová už pokrývajú, čo diktuješ.")
                .font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                .padding(14)

        case .loaded(let suggestions):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let global = suggestions.filter { $0.profileID == nil }
                    if !global.isEmpty {
                        group(title: "Globálne", items: global)
                    }
                    ForEach(profileStore.profiles) { profile in
                        let items = suggestions.filter { $0.profileID == profile.id }
                        if !items.isEmpty {
                            group(title: profile.displayName, items: items)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func group(title: String, items: [KeywordSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.bodyBold(12))
                .padding(.bottom, 4)
            ForEach(items) { item in
                Toggle(isOn: Binding(
                    get: { checked.contains(item.id) },
                    set: { on in
                        if on { checked.insert(item.id) } else { checked.remove(item.id) }
                    }
                )) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.term).font(Theme.bodyBold(12))
                        Text(item.reason).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.checkbox)
                .padding(.vertical, 4)
                .accessibilityLabel("\(item.term) — \(item.reason)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ suggestions: [KeywordSuggestion]) -> some View {
        HStack {
            Button("Zrušiť") { isPresented = false }
            Spacer()
            Button("Pridať vybrané (\(checked.count))") {
                apply(suggestions.filter { checked.contains($0.id) })
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
            .disabled(checked.isEmpty)
            .accessibilityHint("Pridá zaškrtnuté návrhy na koniec príslušného poľa kľúčových slov, existujúce riadky ostanú nezmenené")
        }
        .padding(14)
    }

    // MARK: - Loading

    private func load() async {
        checked = []
        state = .loading
        do {
            let suggestions = try await KeywordSuggestionEngine.suggest()
            checked = Set(suggestions.map(\.id))   // pre-checked, user unchecks what they don't want
            state = .loaded(suggestions)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Applying — append-only, never touches existing lines

    private func apply(_ accepted: [KeywordSuggestion]) {
        let global = accepted.filter { $0.profileID == nil }.map(\.term)
        if !global.isEmpty {
            dictation.defaultKeywords = Self.appended(dictation.defaultKeywords, with: global, existing: AppProfile.parseKeywords(dictation.defaultKeywords))
        }
        for profile in profileStore.profiles {
            let terms = accepted.filter { $0.profileID == profile.id }.map(\.term)
            guard !terms.isEmpty, let idx = profileStore.profiles.firstIndex(where: { $0.id == profile.id }) else { continue }
            profileStore.profiles[idx].keywords = Self.appended(
                profileStore.profiles[idx].keywords, with: terms,
                existing: profileStore.profiles[idx].transcriptionKeywords
            )
        }
    }

    /// Appends only terms not already present (case-insensitive) — a second, field-level dedupe
    /// on top of the engine's, since the user could've typed something new while the popover
    /// was loading. Never reorders or rewrites the existing text.
    private static func appended(_ current: String, with terms: [String], existing: [String]) -> String {
        let existingLower = Set(existing.map { $0.lowercased() })
        let toAdd = terms.filter { !existingLower.contains($0.lowercased()) }
        guard !toAdd.isEmpty else { return current }
        let trimmed = current.hasSuffix("\n") || current.isEmpty ? current : current + "\n"
        return trimmed + toAdd.joined(separator: "\n")
    }
}
