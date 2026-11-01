import AVFoundation
import SwiftUI

struct PlayerScreen: View {
    let request: PlaybackRequest

    @StateObject private var pc = PlayerController()
    @State private var chrome = true
    @State private var fullscreen = false
    @State private var dragging = false
    @State private var dragFraction: Double = 0
    @State private var showCast = false
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        // 站点片源多数拿不到直链，此时整屏交给内嵌播放器，不再退回浏览器
        if request.url.isEmpty, let path = request.webPath {
            WebPlayerScreen(path: path, title: request.title, episode: request.episode)
        } else {
            nativePlayer
        }
    }

    private var nativePlayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerView(player: pc.player)
                .ignoresSafeArea()

            if let err = pc.failed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30)).foregroundStyle(.white.opacity(0.8))
                    Text(err).font(.footnote).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("重试") { pc.load(url: request.url) }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(Theme.brand, in: Capsule()).foregroundStyle(.white)
                        Button("返回") { dismiss() }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(Color.white.opacity(0.14), in: Capsule()).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 24)
            } else if pc.reconnecting {
                // 断流重连时只给一条轻提示，画面留在最后一帧，不打断
                HStack(spacing: 8) {
                    ProgressView().tint(.white).scaleEffect(0.8)
                    Text("网络波动，正在重连")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.45), in: Capsule())
            }

            if chrome {
                overlay.transition(.opacity)
            }
        }
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
        .onAppear {
            pc.load(url: request.url)
            scheduleHide()
        }
        .onDisappear {
            library.saveProgress(request.detail, seconds: pc.current, duration: pc.duration)
            pc.pause()
            OrientationManager.shared.portrait()
        }
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { chrome.toggle() }; scheduleHide() }
        .sheet(isPresented: $showCast) {
            CastSheet(url: request.url, title: request.title)
        }
    }

    // MARK: 控制层

    private var overlay: some View {
        VStack {
            HStack(spacing: 12) {
                Button {
                    if fullscreen { toggleFullscreen() } else { dismiss() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let ep = request.episode {
                        Text(ep).font(.caption2).foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()
                Button { showCast = true } label: {
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 18)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            HStack(spacing: 42) {
                Button { pc.skip(-10) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 26)).foregroundStyle(.white)
                }
                Button { pc.toggle() } label: {
                    Image(systemName: pc.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34)).foregroundStyle(.white)
                }
                Button { pc.skip(10) } label: {
                    Image(systemName: "goforward.10").font(.system(size: 26)).foregroundStyle(.white)
                }
            }

            Spacer()

            VStack(spacing: 10) {
                scrubber
                HStack(spacing: 16) {
                    Text(timeText(dragging ? pc.duration * dragFraction : pc.current))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("/ " + timeText(pc.duration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Button(r == 1.0 ? "倍速 正常" : String(format: "倍速 %.2fx", r)) {
                                pc.setRate(Float(r))
                            }
                        }
                    } label: {
                        Text(pc.rate == 1.0 ? "倍速" : String(format: "%.2fx", pc.rate))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    }

                    Button { toggleFullscreen() } label: {
                        Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left"
                                                     : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, fullscreen ? 20 : 34)
        }
        .padding(.top, fullscreen ? 6 : 44)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let total = max(pc.duration, 0.1)
            let value = dragging ? dragFraction : min(pc.current / total, 1)
            let w = geo.size.width

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 3)
                Capsule().fill(.white.opacity(0.35))
                    .frame(width: max(0, min(w, w * (pc.buffered / total))), height: 3)
                Capsule().fill(Theme.brand).frame(width: max(0, w * value), height: 3)
                Circle().fill(.white)
                    .frame(width: dragging ? 14 : 10, height: dragging ? 14 : 10)
                    .offset(x: max(0, w * value - (dragging ? 7 : 5)))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        dragFraction = min(max(g.location.x / w, 0), 1)
                    }
                    .onEnded { _ in
                        pc.seek(fraction: dragFraction)
                        dragging = false
                        scheduleHide()
                    }
            )
        }
        .frame(height: 20)
    }

    private func toggleFullscreen() {
        withAnimation(.easeInOut(duration: 0.25)) { fullscreen.toggle() }
        if fullscreen { OrientationManager.shared.landscape() }
        else { OrientationManager.shared.portrait() }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard pc.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                await MainActor.run { withAnimation { chrome = false } }
            }
        }
    }

    private func timeText(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "00:00" }
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}

/// AVPlayerLayer 承载视图
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
