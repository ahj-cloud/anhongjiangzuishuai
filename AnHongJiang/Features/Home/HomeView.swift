import SwiftUI

enum LoadState<T> {
    case idle
    case loading
    case loaded(T)
    case failed(String)

    var value: T? {
        if case .loaded(let v) = self { return v }
        return nil
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var state: LoadState<HomeFeed> = .idle
    @Published private(set) var refreshing = false

    func load(force: Bool = false) async {
        if case .loaded = state, !force { return }
        if state.value == nil { state = .loading }
        refreshing = true
        defer { refreshing = false }
        do {
            let feed = try await SiteEngine.shared.loadHome(force: force)
            state = .loaded(feed)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "加载失败")
        }
    }
}

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @State private var showWebFallback = false

    var body: some View {
        NavigationStack {
            Group {
                switch vm.state {
                case .idle, .loading:
                    LoadingView(text: "正在同步片库")
                case .failed(let msg):
                    ErrorStateView(message: msg) {
                        Task { await vm.load(force: true) }
                    }
                case .loaded(let feed):
                    content(feed)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("安宇最帅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showWebFallback = true
                    } label: {
                        Image(systemName: "safari")
                    }
                }
            }
            .navigationDestination(for: MediaItem.self) { item in
                DetailView(item: item)
            }
            .sheet(isPresented: $showWebFallback) {
                WebFallbackView(path: "/")
            }
        }
        .task { await vm.load() }
    }

    private func content(_ feed: HomeFeed) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                HeroBanner(items: feed.hero)
                    .padding(.top, 6)

                ForEach(feed.sections) { section in
                    PosterRail(section: section)
                }

                Text("共 \(feed.sections.reduce(0) { $0 + $1.items.count }) 条资源")
                    .font(.caption2)
                    .foregroundStyle(Theme.subtext)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .padding(.bottom, 24)
        }
        .refreshable { await vm.load(force: true) }
    }
}
