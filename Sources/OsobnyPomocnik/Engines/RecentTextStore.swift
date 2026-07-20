import Foundation
import Observation

/// In-memory cache of recently spoken texts. Clears automatically on app quit.
@Observable
@MainActor
final class RecentTextStore {
    static let shared = RecentTextStore()
    private init() {}

    private(set) var lastText: String?

    func store(_ text: String) {
        lastText = text
    }
}
