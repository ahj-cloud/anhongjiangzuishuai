import AVFoundation
import Combine
import UIKit

struct PlaybackRequest: Identifiable {
    let id = UUID()
    var title: String
    var episode: String?
    /// 直链（m3u8/mp4）。站点大多数片源拿不到，为空时走 webPath 内嵌播放。
    var url: String
    /// 站点播放页路径，形如 /player/av_xxx。非空且 url 为空时用全屏 WebView 播放。
    var webPath: String?
    var sources: [PlaybackSource]
    var detail: MediaItem
}

/// AVPlayer 的薄封装：只暴露界面需要的状态，播放地址一律带 Referer/UA 请求头
final class PlayerController: ObservableObject {

    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var current: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var buffered: Double = 0
    @Published var rate: Float = 1.0
    @Published private(set) var failed: String?
    @Published private(set) var ready = false

    private var timeObserver: Any?
    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?

    init() {
        configureAudioSession()
        player.actionAtItemEnd = .pause
        addObserver()
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }
    }

    deinit {
        if let t = timeObserver { player.removeTimeObserver(t) }
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
    }

    // MARK: 装载

    func load(url: String) {
        guard let u = URL(string: url) else {
            failed = "地址无效"
            return
        }
        ready = false
        failed = nil

        // 站点资源普遍校验来源，缺 Referer 会 403
        let headers: [String: String] = [
            "Referer": SiteConfig.origin + "/",
            "User-Agent": SiteConfig.userAgent,
            "Origin": SiteConfig.origin
        ]
        let asset = AVURLAsset(url: u, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 8
        player.replaceCurrentItem(with: item)

        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                switch it.status {
                case .readyToPlay:
                    self?.ready = true
                    self?.duration = it.duration.seconds.isFinite ? it.duration.seconds : 0
                case .failed:
                    self?.failed = it.error?.localizedDescription ?? "播放失败"
                default:
                    break
                }
            }
        }
        play()
    }

    // MARK: 控制

    func play() {
        player.play()
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        current = seconds
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        seek(to: duration * min(max(fraction, 0), 1))
    }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { player.rate = r }
    }

    func skip(_ delta: Double) {
        seek(to: current + delta)
    }

    // MARK: 内部

    private func addObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            self.current = t.seconds
            if let item = self.player.currentItem, item.duration.seconds.isFinite, item.duration.seconds > 0 {
                self.duration = item.duration.seconds
            }
            if let r = self.player.currentItem?.loadedTimeRanges.last?.timeRangeValue {
                self.buffered = (r.start.seconds + r.duration.seconds)
            }
            self.isPlaying = self.player.rate > 0
        }
    }

    private func configureAudioSession() {
        // 允许后台音频 + 静音键下仍出声，投屏/锁屏时不中断
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetooth])
        try? session.setActive(true)
    }
}

// MARK: - 横竖屏

final class OrientationManager {
    static let shared = OrientationManager()
    private(set) var mask: UIInterfaceOrientationMask = .portrait

    func set(_ m: UIInterfaceOrientationMask) {
        mask = m
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: m))
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIDevice.current.setValue(
                m == .landscape ? UIInterfaceOrientation.landscapeRight.rawValue
                                : UIInterfaceOrientation.portrait.rawValue,
                forKey: "orientation"
            )
        }
    }

    func landscape() { set(.landscape) }
    func portrait() { set(.portrait) }
}
