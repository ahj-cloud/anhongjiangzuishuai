import SwiftUI

@MainActor
final class BrowseViewModel: ObservableObject {
    @Published private(set) var state: LoadState<HomeFeed> = .idle
    @Published var selected = 0

    func load() async {
        if state.value != nil { return }
        state = .loading
        do {
            state = .loaded(try await SiteEngine.shared.loadHome())
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "加载失败")
        }
    }
}

struct BrowseView: View {
    @StateObject private var vm = BrowseViewModel()
    @State private var showWeb = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                switch vm.state {
                case .idle, .loading:
                    LoadingView(text: "正在读取频道")
                case .failed(let msg):
                    ErrorStateView(message: msg) { Task { await vm.load() } }
                case .loaded(let feed):
                    content(feed)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("频道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showWeb = true } label: { Image(systemName: "safari") }
                }
            }
            .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
            .sheet(isPresented: $showWeb) { WebFallbackView(path: "/") }
        }
        .task { await vm.load() }
    }

    private func content(_ feed: HomeFeed) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(feed.sections.enumerated()), id: \.element.id) { idx, s in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { vm.selected = idx }
                        } label: {
                            Text(s.title)
                                .font(.system(size: 13, weight: vm.selected == idx ? .semibold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(
                                    vm.selected == idx ? Theme.brand : Theme.card,
                                    in: Capsule()
                                )
                                .foregroundStyle(vm.selected == idx ? .white : Theme.text)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, 10)
            }

            let section = feed.sections.isEmpty
                ? FeedSection(id: "empty", title: "", items: [])
                : feed.sections[min(vm.selected, feed.sections.count - 1)]
            ScrollView {
                if section.items.isEmpty {
                    EmptyHint(icon: "square.grid.2x2", text: "这个频道还没有内容")
                        .frame(height: 320)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(section.items) { item in
                            NavigationLink(value: item) {
                                PosterCard(item: item, width: 104)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 30)
                }
            }
        }
    }
}
