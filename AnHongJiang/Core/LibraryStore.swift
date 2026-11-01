import Foundation
import Combine

struct HistoryEntry: Codable, Identifiable, Hashable {
    var item: MediaItem
    var episode: String?
    var seconds: Double
    var duration: Double
    var updatedAt: Date

    var id: String { item.id }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }
}

/// 收藏 / 观看记录 / 播放进度，全部落本地 JSON，原子写避免半截文件
@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var favorites: [MediaItem] = []
    @Published private(set) var history: [HistoryEntry] = []

    private struct Payload: Codable {
        var favorites: [MediaItem]
        var history: [HistoryEntry]
    }

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.json")
        load()
    }

    // MARK: 收藏

    func isFavorite(_ item: MediaItem) -> Bool {
        favorites.contains { $0.id == item.id }
    }

    func toggleFavorite(_ item: MediaItem) {
        if let idx = favorites.firstIndex(where: { $0.id == item.id }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(item, at: 0)
        }
        save()
    }

    // MARK: 记录

    func markWatched(_ item: MediaItem, episode: String?) {
        if let idx = history.firstIndex(where: { $0.item.id == item.id }) {
            history[idx].item = item
            history[idx].episode = episode
            history[idx].updatedAt = Date()
            let entry = history.remove(at: idx)
            history.insert(entry, at: 0)
        } else {
            history.insert(HistoryEntry(item: item, episode: episode, seconds: 0,
                                        duration: 0, updatedAt: Date()), at: 0)
        }
        trim()
        save()
    }

    func saveProgress(_ item: MediaItem, seconds: Double, duration: Double) {
        guard seconds > 1 else { return }
        if let idx = history.firstIndex(where: { $0.item.id == item.id }) {
            history[idx].seconds = seconds
            history[idx].duration = duration
            history[idx].updatedAt = Date()
        } else {
            history.insert(HistoryEntry(item: item, episode: nil, seconds: seconds,
                                        duration: duration, updatedAt: Date()), at: 0)
        }
        trim()
        save()
    }

    func progress(for item: MediaItem) -> Double {
        history.first { $0.item.id == item.id }?.progress ?? 0
    }

    func removeHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    // MARK: 落盘

    private func trim() {
        if history.count > 200 { history = Array(history.prefix(200)) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        favorites = p.favorites
        history = p.history
    }

    private func save() {
        let payload = Payload(favorites: favorites, history: history)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
