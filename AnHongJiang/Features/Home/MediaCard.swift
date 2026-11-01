import SwiftUI

struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 108

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: item.posterURL)
                    .frame(width: width, height: width * 1.45)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

                LinearGradient(colors: [.clear, .black.opacity(0.72)],
                               startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

                if let remark = item.remark, !remark.isEmpty {
                    Text(remark)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let score = item.score, !score.isEmpty {
                    ScoreTag(score: score).padding(5)
                }
            }

            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
    }
}

struct PosterRail: View {
    let section: FeedSection
    var onMore: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: section.title, more: onMore)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(section.items) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
            }
        }
    }
}

struct HeroBanner: View {
    let items: [MediaItem]
    @State private var index = 0
    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            GeometryReader { geo in
                TabView(selection: $index) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        NavigationLink(value: item) {
                            ZStack(alignment: .bottomLeading) {
                                RemoteImage(url: item.posterURL)
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .clipped()
                                LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                               startPoint: .center, endPoint: .bottom)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title)
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                    HStack(spacing: 8) {
                                        if let y = item.year { meta(y) }
                                        if let a = item.area { meta(a) }
                                        if let c = item.category { meta(c) }
                                        if let r = item.remark { meta(r) }
                                    }
                                }
                                .padding(16)
                            }
                        }
                        .buttonStyle(.plain)
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 5) {
                        ForEach(0..<min(items.count, 6), id: \.self) { i in
                            Capsule()
                                .fill(i == index % max(items.count, 1) ? Theme.brand : .white.opacity(0.45))
                                .frame(width: i == index % max(items.count, 1) ? 14 : 5, height: 5)
                                .animation(.easeInOut(duration: 0.2), value: index)
                        }
                    }
                    .padding(.trailing, 14).padding(.bottom, 12)
                }
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, Theme.pagePadding)
            .onReceive(timer) { _ in
                guard items.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    index = (index + 1) % items.count
                }
            }
        }
    }

    private func meta(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// 带占位与失败兜底的异步图片
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                placeholder(system: "photo")
            case .empty:
                ZStack {
                    Theme.hairline.opacity(0.5)
                    ProgressView().scaleEffect(0.7).tint(Theme.subtext)
                }
            @unknown default:
                placeholder(system: "photo")
            }
        }
    }

    private func placeholder(system: String) -> some View {
        ZStack {
            Theme.hairline.opacity(0.5)
            Image(systemName: system).foregroundStyle(Theme.subtext)
        }
    }
}
