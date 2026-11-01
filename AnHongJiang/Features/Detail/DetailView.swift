import SwiftUI

@MainActor
final class DetailViewModel: ObservableObject {
    @Published private(set) var state: LoadState<DetailPayload> = .idle
    /// 详情接口没拿到数据、用列表页已知信息兜底时为 true
    @Published private(set) var degraded = false
    private let item: MediaItem

    init(item: MediaItem) { self.item = item }

    func load(force: Bool = false) async {
        if case .loaded = state, !force { return }
        if state.value == nil { state = .loading }
        do {
            let payload = try await SiteEngine.shared.detail(item)
            state = .loaded(payload)
            degraded = false
        } catch {
            // 部分片源的详情路由抓不到数据。这时不弹错误，
            // 用列表页已有的标题/海报/简介兜底，播放交给内嵌播放页自己处理。
            state = .loaded(Self.fallback(item))
            degraded = true
        }
    }

    private static func fallback(_ item: MediaItem) -> DetailPayload {
        DetailPayload(
            item: item,
            episodes: [Episode(id: "main", name: "正片", url: nil, route: item.detailRoute)],
            sources: [],
            related: []
        )
    }
}

struct DetailView: View {
    let item: MediaItem

    @StateObject private var vm: DetailViewModel
    @State private var expanded = false
    @State private var playing: PlaybackRequest?
    @State private var showWeb = false
    @EnvironmentObject private var library: LibraryStore

    init(item: MediaItem) {
        self.item = item
        _vm = StateObject(wrappedValue: DetailViewModel(item: item))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                switch vm.state {
                case .idle, .loading:
                    ProgressView().tint(Theme.brand).frame(maxWidth: .infinity).padding(.vertical, 40)
                case .failed(let msg):
                    ErrorStateView(message: msg) { Task { await vm.load(force: true) } }
                        .frame(height: 240)
                case .loaded(let payload):
                    if vm.degraded { degradedHint }
                    episodes(payload)
                    related(payload)
                }
                Color.clear.frame(height: 72)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task { await vm.load() }
        .fullScreenCover(item: $playing) { req in
            PlayerScreen(request: req)
        }
        .sheet(isPresented: $showWeb) {
            WebFallbackView(path: item.detailRoute)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(url: item.posterURL)
                .frame(width: 108, height: 156)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)

                HStack(spacing: 6) {
                    if let y = item.year { chip(y) }
                    if let a = item.area { chip(a) }
                    if let c = item.category { chip(c) }
                }

                if let remark = item.remark {
                    Text(remark).font(.caption).foregroundStyle(Theme.brand)
                }
                if let score = item.score {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.system(size: 10))
                        Text(score).font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(Theme.brand)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 8)
    }

    private func chip(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(Theme.subtext)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.hairline.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: 兜底提示

    private var degradedHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").font(.system(size: 12))
            Text("该片源详情未取到，可直接点播放")
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.subtext)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, Theme.pagePadding)
    }

    // MARK: 简介

    @ViewBuilder
    private var summaryBlock: some View {
        if let s = vm.state.value?.item.summary, !s.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(s)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(expanded ? nil : 2)
                Button(expanded ? "收起" : "展开") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.brand)
            }
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    // MARK: 选集

    @ViewBuilder
    private func episodes(_ payload: DetailPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryBlock

            HStack(spacing: 8) {
                Text("选集").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if payload.episodes.count > 1 {
                    Text("共 \(payload.episodes.count) 集")
                        .font(.caption).foregroundStyle(Theme.subtext)
                }
                if !payload.sources.isEmpty {
                    Menu {
                        ForEach(payload.sources) { s in
                            Button(s.quality) { play(payload, episode: nil, source: s) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(payload.sources.first?.quality ?? "自动")
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.brand)
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(payload.episodes) { ep in
                    Button {
                        play(payload, episode: ep, source: payload.sources.first)
                    } label: {
                        Text(ep.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(Theme.text)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.hairline, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    @ViewBuilder
    private func related(_ payload: DetailPayload) -> some View {
        if !payload.related.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "相关推荐")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(payload.related) { it in
                            NavigationLink(value: it) { PosterCard(item: it, width: 96) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                }
            }
        }
    }

    // MARK: 底栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                if let payload = vm.state.value {
                    play(payload, episode: payload.episodes.first, source: payload.sources.first)
                } else {
                    showWeb = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("立即播放").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(LinearGradient(colors: [Theme.brand, Theme.brandDeep],
                                           startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 22))
                .foregroundStyle(.white)
            }

            iconButton(library.isFavorite(item) ? "heart.fill" : "heart") {
                library.toggleFavorite(item)
            }
            iconButton("rectangle.on.rectangle") { showWeb = true }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .background(Theme.card, in: Circle())
        }
    }

    // MARK: 播放

    private func play(_ payload: DetailPayload, episode: Episode?, source: PlaybackSource?) {
        var url: String? = episode?.url ?? source?.url
        if url == nil { url = payload.sources.first?.url }

        library.markWatched(payload.item, episode: episode?.name)

        // 站点片源没有直链（要先换 token 再由播放器向 provider 取分片），
        // 所以拿不到直链时不退出 App，改为整屏内嵌站点播放页。
        let path = episode?.route.flatMap { $0.isEmpty ? nil : $0 } ?? payload.item.detailRoute
        playing = PlaybackRequest(
            title: payload.item.title,
            episode: episode?.name,
            url: url ?? "",
            webPath: path,
            sources: payload.sources,
            detail: payload.item
        )
    }
}
