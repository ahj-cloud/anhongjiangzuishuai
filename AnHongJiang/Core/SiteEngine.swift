import Foundation
import WebKit

/// 数据引擎。
///
/// 站点所有 `/v1/*` 接口都带 HMAC 请求签名（密钥随构建变化），原生端复刻签名不现实。
/// 这里改用内置 WKWebView 跑站点自己的 JS：签名由页面脚本完成，App 在 documentStart
/// 注入钩子把 `fetch` / `XMLHttpRequest` 的响应体捞出来，再交给 FeedParser 归一。
/// 好处是站点换密钥、加反爬、改字段都不需要改 App。
final class SiteEngine: NSObject, ObservableObject {

    static let shared = SiteEngine()

    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?

    private(set) lazy var webView: WKWebView = makeWebView()

    private struct Capture {
        let url: String
        let body: Any
        let at: Date
    }

    private var captures: [Capture] = []
    private let maxCaptures = 80
    private var lastHome: HomeFeed?

    private override init() {
        super.init()
        _ = webView          // 触发懒加载，开始预热
    }

    // MARK: - 对外接口

    private var homeTask: Task<HomeFeed, Error>?

    func loadHome(force: Bool = false) async throws -> HomeFeed {
        if !force, let cached = lastHome { return cached }
        // 首页和频道页会同时请求，这里合并成一次导航，避免 WebView 被来回打断
        if let running = homeTask { return try await running.value }

        let task = Task<HomeFeed, Error> { [weak self] in
            guard let self else { throw SiteError.timeout }
            let bodies = try await self.visit(path: SiteConfig.homePath, timeout: 18) { $0.contains("/v1/") }
            let feed = FeedParser.home(from: self.merge(bodies))
            guard !feed.sections.isEmpty || !feed.hero.isEmpty else {
                throw SiteError.empty("首页没有解析出条目")
            }
            return feed
        }
        homeTask = task

        do {
            let feed = try await task.value
            lastHome = feed
            homeTask = nil
            return feed
        } catch {
            homeTask = nil
            throw error
        }
    }

    func browse(path: String) async throws -> [MediaItem] {
        let bodies = try await visit(path: path, timeout: 18) { $0.contains("/v1/") }
        let items = FeedParser.items(from: merge(bodies))
        guard !items.isEmpty else { throw SiteError.empty("该频道暂无内容") }
        return items
    }

    func search(_ keyword: String) async throws -> [MediaItem] {
        let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        // 搜索参数名不确定，按常见写法依次尝试，命中即返回
        for param in ["q", "keyword", "wd", "search"] {
            guard let bodies = try? await visit(path: "/search?\(param)=\(q)", timeout: 12,
                                                match: { $0.contains("/v1/") || $0.lowercased().contains("search") })
            else { continue }
            let items = FeedParser.items(from: merge(bodies))
            if !items.isEmpty { return items }
        }
        throw SiteError.empty("没有搜到「\(keyword)」")
    }

    func detail(_ item: MediaItem) async throws -> DetailPayload {
        let bodies = try await visit(path: item.detailRoute, timeout: 20) { url in
            url.contains("/v1/")
        }
        let payload = FeedParser.detail(from: merge(bodies), fallback: item)
        if payload.sources.isEmpty {
            // 播放地址可能由页面二次请求拿到，兜底从 DOM 里抠一次
            if let src = await probeVideoSource() {
                var p = payload
                p.sources = [PlaybackSource(url: src, quality: "自动")]
                return p
            }
        }
        return payload
    }

    /// 从当前页面 <video> 上取直链，拿不到返回 nil
    func probeVideoSource() async -> String? {
        let js = """
        (function(){
          var v = document.querySelector('video');
          if (v && v.currentSrc) return v.currentSrc;
          if (v && v.src) return v.src;
          var s = document.querySelectorAll('source');
          for (var i=0;i<s.length;i++){ if (s[i].src) return s[i].src; }
          return '';
        })()
        """
        do {
            let value = try await evaluate(js)
            guard let s = value as? String, s.hasPrefix("http") else { return nil }
            return s
        } catch {
            return nil
        }
    }

    func evaluate(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            DispatchQueue.main.async {
                self.webView.evaluateJavaScript(js) { value, error in
                    if let error = error { cont.resume(throwing: error) }
                    else { cont.resume(returning: value) }
                }
            }
        }
    }

    // MARK: - 导航 + 抓包

    private func visit(path: String, timeout: TimeInterval,
                       match: @escaping (String) -> Bool) async throws -> [Any] {
        let start = Date()
        let url = SiteConfig.url(path)
        await MainActor.run {
            self.lastError = nil
            self.webView.stopLoading()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
            req.setValue(SiteConfig.userAgent, forHTTPHeaderField: "User-Agent")
            self.webView.load(req)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var hit: [Capture] = []
        while Date() < deadline {
            hit = snapshotCaptures(since: start, match: match)
            if !hit.isEmpty { break }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        guard !hit.isEmpty else {
            await MainActor.run { self.lastError = "页面数据没有返回" }
            throw SiteError.timeout
        }
        // 首个响应之后通常还有详情/播放地址等后续请求，多等一会儿收齐
        try? await Task.sleep(nanoseconds: 900_000_000)
        hit = snapshotCaptures(since: start, match: match)
        return hit.map { $0.body }
    }

    private func snapshotCaptures(since: Date, match: (String) -> Bool) -> [Capture] {
        lock.lock()
        let all = captures
        lock.unlock()
        return all.filter { $0.at >= since && match($0.url) }
    }

    private func merge(_ bodies: [Any]) -> Any {
        if bodies.count == 1 { return bodies[0] }
        return bodies
    }

    private func record(url: String, body: Any) {
        lock.lock()
        captures.append(Capture(url: url, body: body, at: Date()))
        if captures.count > maxCaptures { captures.removeFirst(captures.count - maxCaptures) }
        lock.unlock()
    }

    private let lock = NSLock()

    // MARK: - WebView 构建

    private func makeWebView() -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()          // 复用 Cookie，登录态可保留
        conf.defaultWebpagePreferences.allowsContentJavaScript = true
        conf.allowsInlineMediaPlayback = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.userContentController.add(self, name: "bpz")
        conf.userContentController.addUserScript(
            WKUserScript(source: Self.captureJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: conf)
        wv.customUserAgent = SiteConfig.userAgent
        wv.navigationDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = .clear
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        wv.load(URLRequest(url: SiteConfig.homeURL))
        return wv
    }

    // MARK: - 注入脚本

    private static let captureJS = """
    (function () {
      if (window.__bpzHooked) { return; }
      window.__bpzHooked = true;

      function post(url, text) {
        if (!text || text.length > 4000000) { return; }
        try {
          window.webkit.messageHandlers.bpz.postMessage({ url: String(url), body: String(text) });
        } catch (e) {}
        try {
          window.__bpzLog = window.__bpzLog || [];
          window.__bpzLog.push({ url: String(url), body: String(text) });
          if (window.__bpzLog.length > 40) { window.__bpzLog.shift(); }
        } catch (e) {}
      }

      function want(url) {
        var u = String(url || '');
        return u.indexOf('/v1/') >= 0 || u.indexOf('/api/') >= 0;
      }

      var of = window.fetch;
      if (of) {
        window.fetch = function (input, init) {
          var url = (typeof input === 'string') ? input : (input && input.url) || '';
          return of.apply(this, arguments).then(function (res) {
            try {
              if (want(url) && res && res.clone) {
                res.clone().text().then(function (t) { post(url, t); }).catch(function () {});
              }
            } catch (e) {}
            return res;
          });
        };
      }

      var oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) {
        this.__bpzUrl = u;
        return oo.apply(this, arguments);
      };
      var os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        var xhr = this;
        xhr.addEventListener('load', function () {
          try {
            if (want(xhr.__bpzUrl) && xhr.responseText) { post(xhr.__bpzUrl, xhr.responseText); }
          } catch (e) {}
        });
        return os.apply(this, arguments);
      };
    })();
    """
}

enum SiteError: LocalizedError {
    case timeout
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "网络超时，换个网络再试"
        case .empty(let msg): return msg
        }
    }
}

// MARK: - 消息 / 导航回调

extension SiteEngine: WKScriptMessageHandler, WKNavigationDelegate {

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let url = dict["url"] as? String,
              let text = dict["body"] as? String,
              let data = text.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return }
        record(url: url, body: json)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async { self.isReady = true }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }
}
