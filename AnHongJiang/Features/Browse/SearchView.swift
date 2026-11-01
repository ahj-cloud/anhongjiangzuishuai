import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published private(set) var state: LoadState<[MediaItem]> = .idle
    @Published var keyword = ""
    @Published private(set) var searching = false
    /// 已有本地结果、远端还在补全时置 true（结果区顶部显示一条细进度条，不遮挡列表）
    @Published private(set) var refining = false
    /// 输入时的本地联想，纯内存匹配，不发网络
    @Published private(set) var hints: [MediaItem] = []

    private let historyKey = "bpz.search.history"
    private var seq = 0          // 请求序号，防止先发后到覆盖新结果

    var recent: [String] {
        UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    /// 每次输入调用，只查本地语料，保证键入无延迟
    func updateHints(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { hints = []; return }
        hints = Array(SiteEngine.shared.localSearch(t, limit: 6))
    }

    func search(_ text: String? = nil) async {
        let q = (text ?? keyword).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        keyword = q

        seq += 1
        let mySeq = seq

        // 第一层：本地片库匹配，立刻出结果，不用等网络
        let local = SiteEngine.shared.localSearch(q)
        if !local.isEmpty {
            state = .loaded(local)
            refining = true
            searching = true
        } else {
            state = .loading
            searching = true
            refining = false
        }

        // 第二层：远端完整搜索（AI 会话，3~8 秒），回来后覆盖
        do {
            let items = try await SiteEngine.shared.search(q)
            guard mySeq == seq else { return }        // 已发起新搜索，丢弃旧结果
            state = .loaded(items)
            remember(q)
        } catch {
            guard mySeq == seq else { return }
            if local.isEmpty {
                state = .failed((error as? LocalizedError)?.errorDescription ?? "搜索失败")
            }
            // 本地已有结果就保留，不弹错误
        }
        if mySeq == seq {
            searching = false
            refining = false
        }
    }

    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: historyKey)
        objectWillChange.send()
    }

    private func remember(_ q: String) {
        var list = recent.filter { $0 != q }
        list.insert(q, at: 0)
        UserDefaults.standard.set(Array(list.prefix(12)), forKey: historyKey)
    }
}

struct SearchView: View {
    @StateObject private var vm = SearchViewModel()
    @State private var showWeb = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                switch vm.state {
                case .idle:
                    if vm.hints.isEmpty { suggestions } else { hintList }
                case .loading:
                    LoadingView(text: "AI 正在检索，请稍候")
                case .failed(let msg):
                    VStack(spacing: 16) {
                        ErrorStateView(message: msg)
                        Button("在网页里搜") { showWeb = true }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.brand)
                    }
                case .loaded(let items):
                    results(items)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $vm.keyword, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "片名、演员、关键词")
            .onSubmit(of: .search) { Task { await vm.search() } }
            .onChange(of: vm.keyword) { _, newValue in
                vm.updateHints(newValue)          // 纯本地匹配，键入不卡
            }
            .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
            .sheet(isPresented: $showWeb) {
                WebFallbackView(path: "/search?q=\(vm.keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
            }
        }
    }

    /// 输入时的本地联想：点一条直接进详情，不用等远端
    private var hintList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.hints) { item in
                    NavigationLink(value: item) {
                        HStack(spacing: 12) {
                            RemoteImage(url: item.posterURL)
                                .frame(width: 42, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    if let y = item.year {
                                        Text(y).font(.system(size: 11)).foregroundStyle(Theme.subtext)
                                    }
                                    if let r = item.remark {
                                        Text(r).font(.system(size: 11)).foregroundStyle(Theme.brand)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.subtext)
                        }
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, Theme.pagePadding + 54)
                }

                // 本地没有的，交给远端 AI 搜
                Button {
                    Task { await vm.search() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                        Text("在 AI 片库里搜索「\(vm.keyword)」")
                            .font(.system(size: 13.5))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var suggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !vm.recent.isEmpty {
                    HStack {
                        Text("搜索历史").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button("清空") { vm.clearHistory() }
                            .font(.caption).foregroundStyle(Theme.subtext)
                    }
                    FlowTags(items: vm.recent) { q in
                        Task { await vm.search(q) }
                    }
                }
                Text("热门搜索").font(.system(size: 15, weight: .semibold))
                FlowTags(items: ["玩具总动员", "牧神记", "仙逆", "年会不能停", "现在就出发"], onTap: { q in
                    Task { await vm.search(q) }
                })
            }
            .padding(Theme.pagePadding)
        }
    }

    private func results(_ items: [MediaItem]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // 远端还在补全时显示一条细进度条，不遮挡已有结果
                if vm.refining {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Theme.brand)
                        .frame(height: 2)
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.top, 6)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { PosterCard(item: item, width: 104) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(Theme.pagePadding)
            }
        }
    }
}

/// 简单的自动换行标签流
struct FlowTags: View {
    let items: [String]
    var onTap: (String) -> Void

    var body: some View {
        let screen = UIScreen.main.bounds.width - Theme.pagePadding * 2
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows(screen), id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { tag in
                        Button { onTap(tag) } label: {
                            Text(tag)
                                .font(.system(size: 13))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Theme.card, in: Capsule())
                                .foregroundStyle(Theme.text)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func rows(_ maxWidth: CGFloat) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var used: CGFloat = 0
        for tag in items {
            let w = CGFloat(tag.count) * 13 + 24 + 8
            if used + w > maxWidth, !current.isEmpty {
                result.append(current)
                current = [tag]
                used = w
            } else {
                current.append(tag)
                used += w
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
