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
            // 把首页所有条目沉成一份本地语料，搜索时先做本地过滤，避免每次都干等远端
            var seen = Set<String>()
            corpus = (feed.hero + feed.sections.flatMap { $0.items }).filter {
                seen.insert($0.id).inserted
            }
            return feed
        } catch {
            homeTask = nil
            throw error
        }
    }

    /// 本地语料库：首页已加载的全部条目，用于搜索时即时出结果
    private var corpus: [MediaItem] = []

    /// 先在本地片库里模糊匹配，命中即为「秒出」结果；远端结果回来后覆盖。
    func localSearch(_ word: String, limit: Int = 40) -> [MediaItem] {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty else { return [] }
        var exact: [MediaItem] = []
        var fuzzy: [MediaItem] = []
        for item in corpus {
            let title = item.title.lowercased()
            if title.contains(w) {
                exact.append(item)
            } else if let sum = item.summary?.lowercased(), sum.contains(w) {
                fuzzy.append(item)
            }
        }
        // 标题命中的排前面，简介命中的补后面
        return Array((exact + fuzzy).prefix(limit))
    }

    func browse(path: String) async throws -> [MediaItem] {
        let bodies = try await visit(path: path, timeout: 18) { $0.contains("/v1/") }
        let items = FeedParser.items(from: merge(bodies))
        guard !items.isEmpty else { throw SiteError.empty("该频道暂无内容") }
        return items
    }

    /// 搜索结果缓存。AI 会话链路单次要 3~8 秒，同词重复搜必须命中缓存。
    private var searchCache: [String: (items: [MediaItem], at: Date)] = [:]
    private let searchCacheTTL: TimeInterval = 300      // 5 分钟
    private let searchCacheLimit = 40

    func search(_ keyword: String) async throws -> [MediaItem] {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { throw SiteError.empty("关键词为空") }

        if let hit = searchCache[word], Date().timeIntervalSince(hit.at) < searchCacheTTL {
            return hit.items
        }

        // 站点真实搜索路由：/session/new?pending=1&submission=<q>
        // （路由表里没有 /search，按 /search?q= 请求只会 404 后空等超时）
        let q = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
        let path = "/session/new?pending=1&submission=\(q)"

        let bodies = try await visit(path: path, timeout: 30,
                                     match: { url in
                                         url.contains("/v1/") || url.contains("/session")
                                     },
                                     settle: 4)
        let items = FeedParser.items(from: merge(bodies))
        guard !items.isEmpty else { throw SiteError.empty("没有搜到「\(word)」") }

        searchCache[word] = (items, Date())
        if searchCache.count > searchCacheLimit {
            // 超限时按时间淘汰最旧的一批
            let sorted = searchCache.sorted { $0.value.at < $1.value.at }
            for (k, _) in sorted.prefix(searchCache.count - searchCacheLimit) {
                searchCache.removeValue(forKey: k)
            }
        }
        return items
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

    /// 导航到指定路径并收集 `/v1/*` 响应体。
    ///
    /// 优先走站内软跳转（history.pushState + popstate），SPA 已加载时省掉 1~3 秒的整页重载；
    /// 软跳转 3 秒内没数据再退回整页 load 兜底。
    /// settle 表示「连续多少次采样没有新增数据就认为收齐」，替代原先固定的 900ms 盲等。
    private func visit(path: String, timeout: TimeInterval,
                       match: @escaping (String) -> Bool,
                       settle: Int = 3) async throws -> [Any] {
        let start = Date()
        let url = SiteConfig.url(path)

        let soft = await softNavigate(path)
        if !soft {
            await hardLoad(url, timeout: timeout)
        }

        // 软跳转窗口：AI 搜索会话首个响应常在 3~5 秒，给 8 秒；给太短会误判成路由失效
        let softWindow = min(timeout, 8)
        var hit = await waitForCapture(since: start, match: match,
                                       deadline: Date().addingTimeInterval(soft ? softWindow : timeout))

        if hit.isEmpty && soft {
            // 软跳转没触发路由（站点可能自定义了导航），退回整页加载
            await hardLoad(url, timeout: timeout)
            hit = await waitForCapture(since: start, match: match,
                                       deadline: Date().addingTimeInterval(timeout))
        }

        guard !hit.isEmpty else {
            await MainActor.run { self.lastError = "页面数据没有返回" }
            throw SiteError.timeout
        }

        // 流式接口（AI 搜索会话）：等数据不再增长，而不是固定睡死
        var lastCount = hit.count
        var idle = 0
        let cap = Date().addingTimeInterval(8)
        while idle < settle && Date() < cap {
            try? await Task.sleep(nanoseconds: 250_000_000)
            hit = snapshotCaptures(since: start, match: match)
            if hit.count == lastCount { idle += 1 } else { idle = 0; lastCount = hit.count }
        }
        return hit.map { $0.body }
    }

    private func hardLoad(_ url: URL, timeout: TimeInterval) async {
        await MainActor.run {
            self.lastError = nil
            self.webView.stopLoading()
            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.setValue(SiteConfig.userAgent, forHTTPHeaderField: "User-Agent")
            self.webView.load(req)
        }
    }

    private func waitForCapture(since: Date, match: (String) -> Bool,
                                deadline: Date) async -> [Capture] {
        var hit: [Capture] = []
        while Date() < deadline {
            hit = snapshotCaptures(since: since, match: match)
            if !hit.isEmpty { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return hit
    }

    /// 站内软跳转：只改路由不重载页面。返回 false 表示当前没有可用页面或站点不认。
    private func softNavigate(_ path: String) async -> Bool {
        guard isReady else { return false }
        let literal = Self.jsLiteral(path)
        let js = """
        (function(){
          try {
            var p = \(literal);
            if (!p) { return 'fail'; }
            history.pushState({}, '', p);
            window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
            window.dispatchEvent(new Event('popstate'));
            return 'pushed';
          } catch (e) { return 'fail'; }
        })()
        """
        let r = try? await evaluate(js)
        return (r as? String) == "pushed"
    }

    /// 把 Swift 字符串转成可安全嵌进 JS 的字面量
    private static func jsLiteral(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        guard let d = data, let arr = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast())     // 去掉外层 [ ]
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
