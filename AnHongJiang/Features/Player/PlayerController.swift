import AVFoundation
import Combine
import SystemConfiguration
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

/// AVPlayer 的薄封装。
///
/// 站点片源是无签名的公开 HLS，卡顿几乎全部来自三件事：
/// ① 默认缓冲目标 8s，弱网下边下边播到一半就断粮；
/// ② 蜂窝网络下 AVPlayer 会挑高码率档位，实际带宽撑不住；
/// ③ 分片请求偶发超时后 item 直接进入 failed，界面就停在那里。
/// 这里分别用缓冲目标、峰值码率上限、卡顿自动重连来处理。
final class PlayerController: ObservableObject {

    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var current: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var buffered: Double = 0
    @Published var rate: Float = 1.0
    @Published private(set) var failed: String?
    @Published private(set) var ready = false
    /// 卡顿后正在重连：界面显示一条轻提示，不打断画面
    @Published private(set) var reconnecting = false

    private var timeObserver: Any?
    private var statusObs: NSKeyValueObservation?
    private var bufferObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var stallObs: NSObjectProtocol?
    private var failEndObs: NSObjectProtocol?

    private var currentURL = ""
    /// 断线重连时要从这里接着播，不能用 0
    private var resumeAt: Double = 0
    private var retries = 0
    private let maxRetries = 3

    init() {
        configureAudioSession()
        player.actionAtItemEnd = .pause
        // 网络抖动时让 AVPlayer 等待而不是立刻报错，这是起播稳定性的关键开关
        player.automaticallyWaitsToMinimizeStalling = true
        addObserver()
        registerNotifications()
    }

    deinit {
        if let t = timeObserver { player.removeTimeObserver(t) }
        for o in [endObs, stallObs, failEndObs].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(o)
        }
    }

    // MARK: 装载

    func load(url: String) {
        retries = 0
        resumeAt = 0
        attach(urlString: url, seekTo: 0)
    }

    private func attach(urlString: String, seekTo: Double) {
        guard let u = URL(string: urlString) else {
            failed = "地址无效"
            return
        }
        currentURL = urlString
        ready = false
        failed = nil

        let item = makeItem(url: u)
        player.replaceCurrentItem(with: item)

        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch it.status {
                case .readyToPlay:
                    self.ready = true
                    self.retries = 0                       // 真的播起来了才清零，否则重试额度会被白吃
                    self.duration = it.duration.seconds.isFinite ? it.duration.seconds : 0
                    if seekTo > 0 { self.seek(to: seekTo) }
                    self.play()
                case .failed:
                    self.recover(reason: it.error?.localizedDescription ?? "播放失败")
                default:
                    break
                }
            }
        }
        // 缓冲进度：用于界面上的缓冲条，也用来判断是否真的卡住
        bufferObs = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] it, _ in
            guard let r = it.loadedTimeRanges.last?.timeRangeValue else { return }
            let end = r.start.seconds + r.duration.seconds
            DispatchQueue.main.async { self?.buffered = end }
        }
        play()
    }

    /// 组装 item：请求头 + 缓冲目标 + 码率上限
    private func makeItem(url: URL) -> AVPlayerItem {
        // 站点资源校验来源，缺 Referer 会 403
        let headers: [String: String] = [
            "Referer": SiteConfig.origin + "/",
            "User-Agent": SiteConfig.userAgent,
            "Origin": SiteConfig.origin
        ]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])

        // 蜂窝网络限制峰值码率。AVPlayer 只会从 master playlist 里挑不超过这个值的最高档，
        // 不写死具体档位，所以 WiFi 下仍然是最高画质。
        let peak: Double? = isExpensiveNetwork ? 1_600_000 : nil
        let item = AVPlayerItem(asset: asset)
        if let peak { item.preferredPeakBitRate = peak }
        // 8s（默认）在弱网下起播就断粮，15s 让播放器提前囤够一个缓冲周期
        item.preferredForwardBufferDuration = 15
        // 暂停时也继续拉分片，恢复播放不用重新等
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return item
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

    /// 缓冲够不够再播：界面用它决定要不要显示「缓冲中」
    var bufferedAhead: Double {
        max(0, buffered - current)
    }

    // MARK: 断流重连

    private func registerNotifications() {
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }
        // 缓冲区耗尽：不报错，只在原地重连，画面停在最后一帧
        stallObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main
        ) { [weak self] n in
            guard let self, let it = n.object as? AVPlayerItem, it === self.player.currentItem else { return }
            self.recover(reason: "网络抖动")
        }
        // 分片连续失败、item 被判死：同样走重连
        failEndObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] n in
            guard let self, let it = n.object as? AVPlayerItem, it === self.player.currentItem else { return }
            self.recover(reason: "播放中断")
        }
    }

    /// 重建 item 从当前进度续播。退避 1.2s / 2.4s / 3.6s，三次仍失败才报错。
    private func recover(reason: String) {
        guard !currentURL.isEmpty else { return }
        guard retries < maxRetries else {
            reconnecting = false
            failed = "\(reason)，已重试 \(maxRetries) 次"
            return
        }
        guard !reconnecting else { return }

        reconnecting = true
        retries += 1
        resumeAt = current
        let delay = Double(retries) * 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reconnecting = false
            // m3u8 的 token 有时效，原地址失效时由上层重新解析后调用 load(url:)
            self.attach(urlString: self.currentURL, seekTo: self.resumeAt)
        }
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
            self.isPlaying = self.player.rate > 0
        }
    }

    private var isExpensiveNetwork: Bool {
        let reach = SCNetworkReachabilityCreateWithName(nil, "bpz3.com")
        guard let r = reach else { return false }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(r, &flags) else { return false }
        return flags.contains(.isWWAN)
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
