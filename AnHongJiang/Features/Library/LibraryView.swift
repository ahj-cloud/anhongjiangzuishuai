import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("bpz.preferHD") private var preferHD = true
    @AppStorage("bpz.autoPlayNext") private var autoPlayNext = true
    @State private var showWeb = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(Theme.brand.opacity(0.85))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("本地账户").font(.system(size: 17, weight: .semibold))
                            Text("收藏与观看记录保存在本机")
                                .font(.caption).foregroundStyle(Theme.subtext)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("我的影视") {
                    NavigationLink { HistoryListView() } label: {
                        row("clock.arrow.circlepath", "观看记录", "\(library.history.count)")
                    }
                    NavigationLink { FavoriteListView() } label: {
                        row("heart", "我的收藏", "\(library.favorites.count)")
                    }
                }

                Section("播放") {
                    Toggle(isOn: $preferHD) {
                        row("4k.tv", "优先高清", nil)
                    }
                    Toggle(isOn: $autoPlayNext) {
                        row("play.circle", "自动连播下一集", nil)
                    }
                }

                Section("其他") {
                    Button { showWeb = true } label: {
                        row("safari", "打开网页版", nil)
                    }
                    NavigationLink { AboutView() } label: {
                        row("info.circle", "关于安宇最帅", "1.0.0")
                    }
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showWeb) { WebFallbackView(path: "/") }
        }
    }

    private func row(_ icon: String, _ title: String, _ trailing: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.brand)
                .frame(width: 26)
            Text(title).foregroundStyle(Theme.text)
            Spacer()
            if let t = trailing {
                Text(t).font(.caption).foregroundStyle(Theme.subtext)
            }
        }
    }
}

struct HistoryListView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Group {
            if library.history.isEmpty {
                EmptyHint(icon: "clock", text: "还没有观看记录")
            } else {
                List {
                    ForEach(library.history) { entry in
                        NavigationLink(value: entry.item) {
                            HStack(spacing: 12) {
                                RemoteImage(url: entry.item.posterURL)
                                    .frame(width: 64, height: 92)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.item.title)
                                        .font(.system(size: 15, weight: .medium))
                                        .lineLimit(1)
                                    if let ep = entry.episode {
                                        Text(ep).font(.caption).foregroundStyle(Theme.subtext)
                                    }
                                    ProgressView(value: entry.progress)
                                        .tint(Theme.brand)
                                        .frame(height: 3)
                                    Text("观看至 \(Int(entry.progress * 100))%")
                                        .font(.caption2).foregroundStyle(Theme.subtext)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .onDelete { idx in
                        idx.map { library.history[$0] }.forEach(library.removeHistory)
                    }
                }
                .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
            }
        }
        .navigationTitle("观看记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !library.history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { library.clearHistory() }
                        .foregroundStyle(Theme.brand)
                }
            }
        }
    }
}

struct FavoriteListView: View {
    @EnvironmentObject private var library: LibraryStore
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        Group {
            if library.favorites.isEmpty {
                EmptyHint(icon: "heart", text: "还没有收藏")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(library.favorites) { item in
                            NavigationLink(value: item) {
                                ZStack(alignment: .topTrailing) {
                                    PosterCard(item: item, width: 104)
                                    Button {
                                        library.toggleFavorite(item)
                                    } label: {
                                        Image(systemName: "heart.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.brand)
                                            .padding(5)
                                            .background(.ultraThinMaterial, in: Circle())
                                            .padding(4)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Theme.pagePadding)
                }
                .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
            }
        }
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Text("应用名称")
                    Spacer()
                    Text("安宇最帅").foregroundStyle(Theme.subtext)
                }
                HStack {
                    Text("版本")
                    Spacer()
                    Text("1.0.0").foregroundStyle(Theme.subtext)
                }
                HStack {
                    Text("内容来源")
                    Spacer()
                    Text("bpz3.com").foregroundStyle(Theme.subtext)
                }
            }
            Section("说明") {
                Text("片库与播放地址由 bpz3.com 下发，App 负责展示、播放与投屏。")
                    .font(.footnote)
                    .foregroundStyle(Theme.subtext)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct EmptyHint: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.subtext.opacity(0.7))
            Text(text).font(.subheadline).foregroundStyle(Theme.subtext)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
