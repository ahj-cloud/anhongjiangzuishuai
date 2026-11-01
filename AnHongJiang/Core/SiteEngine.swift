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
        restoreCorpus()      // 先把上次的片库读回来，搜索联想不用等首页
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
            // 首页条目沉进本地语料，搜索时先做本地过滤，避免每次都干等远端
            mergeIntoCorpus(feed.hero + feed.sections.flatMap { $0.items })
            return feed
        } catch {
            homeTask = nil
            throw error
        }
    }

    /// 本地语料库：首页已加载的全部条目，用于搜索时即时出结果
    private var corpus: [MediaItem] = []

    private var corpusFile: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("bpz_corpus.json")
    }

    /// 落盘，下次启动立刻有联想数据，不用等首页加载完
    private func persistCorpus() {
        let slice = Array(corpus.prefix(800))
        guard let data = try? JSONEncoder().encode(slice) else { return }
        try? data.write(to: corpusFile, options: .atomic)   // 原子写，避免半截文件
    }

    private func restoreCorpus() {
        guard corpus.isEmpty,
              let data = try? Data(contentsOf: corpusFile),
              let list = try? JSONDecoder().decode([MediaItem].self, from: data)
        else { return }
        corpus = list
    }

    /// 把新出现的条目并进语料，搜索/浏览越用越全
    private func mergeIntoCorpus(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        var added = 0
        lock.lock()
        var index = Set(corpus.map { $0.id })
        for it in items where index.insert(it.id).inserted {
            corpus.append(it)
            added += 1
        }
        lock.unlock()
        if added > 0 { persistCorpus() }        // 磁盘写在锁外
    }

    /// 先在本地片库里模糊匹配，命中即为「秒出」结果；远端结果回来后覆盖。
    func localSearch(_ word: String, limit: Int = 40) -> [MediaItem] {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty else { return [] }

        lock.lock()
        let snapshot = corpus
        lock.unlock()

        if snapshot.isEmpty {
            restoreCorpus()
            lock.lock()
            let again = corpus
            lock.unlock()
            return Self.filter(again, by: w, limit: limit)
        }
        return Self.filter(snapshot, by: w, limit: limit)
    }

    private static func filter(_ pool: [MediaItem], by w: String, limit: Int) -> [MediaItem] {
        var exact: [MediaItem] = []
        var fuzzy: [MediaItem] = []
        for item in pool {
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
        let sent = Self.normalizeQuery(word)
        let q = sent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sent
        let path = "/session/new?pending=1&submission=\(q)"

        let bodies = try await visit(path: path, timeout: 30,
                                     match: { url in
                                         url.contains("/v1/") || url.contains("/session")
                                     },
                                     settle: 4)
        let items = FeedParser.items(from: merge(bodies))
        guard !items.isEmpty else { throw SiteError.empty("没有搜到「\(word)」") }

        searchCache[word] = (items, Date())
        mergeIntoCorpus(items)
        if searchCache.count > searchCacheLimit {
            // 超限时按时间淘汰最旧的一批
            let sorted = searchCache.sorted { $0.value.at < $1.value.at }
            for (k, _) in sorted.prefix(searchCache.count - searchCacheLimit) {
                searchCache.removeValue(forKey: k)
            }
        }
        return items
    }

    /// 「现在就出发第四季」→「现在就出发 第四季」
    ///
    /// 站点搜索是 AI 会话，按自然语言切词匹配。季数紧贴在片名后面时，
    /// 模型容易把整串当成一个片名去找，隔开一位命中率明显更高。
    static func normalizeQuery(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = s.range(of: #"第[0-9一二三四五六七八九十]+[季部集期]"#,
                              options: .regularExpression),
              r.lowerBound != s.startIndex else { return s }
        // 前一位已经是空格或标点就不再插
        let prev = s[s.index(before: r.lowerBound)]
        if prev != " " && prev != "·" && prev != "-" {
            s.insert(" ", at: r.lowerBound)
        }
        return s
    }

    func detail(_ item: MediaItem) async throws -> DetailPayload {
        // 失败会走兜底，别把用户晾太久
        let bodies = try await visit(path: item.detailRoute, timeout: 10) { url in
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

    // MARK: - 播放地址解析

    /// 播放页里 hls.js 拉取的 m3u8/mp4 地址（带 token 的完整 URL）
    private var mediaURLs: [(url: String, at: Date)] = []
    private let maxMedia = 40
    /// 解析结果缓存：item.id -> m3u8。m3u8 的 token 有有效期，
    /// 不能永久缓存，过期后 AVPlayer 会连续 403 卡住。
    private var streamCache: [String: (url: String, at: Date)] = [:]
    private let streamCacheTTL: TimeInterval = 900
    /// 正在解析中的任务，避免同一集被并发解析两次
    private var streamTasks: [String: Task<String?, Never>] = [:]

    private func recordMedia(_ url: String) {
        lock.lock()
        mediaURLs.append((url, Date()))
        if mediaURLs.count > maxMedia { mediaURLs.removeFirst(mediaURLs.count - maxMedia) }
        lock.unlock()
    }

    private func latestStream(since: Date) -> String? {
        lock.lock()
        let list = mediaURLs
        lock.unlock()
        let fresh = list.filter { $0.at >= since }
        // 优先 m3u8，其次 mp4；页面给的可能是相对路径，补成绝对地址
        if let m3u8 = fresh.last(where: { $0.url.contains(".m3u8") }) {
            return Self.normalizeURL(m3u8.url)
        }
        if let other = fresh.last {
            return Self.normalizeURL(other.url)
        }
        return nil
    }

    private static func normalizeURL(_ raw: String) -> String {
        if raw.hasPrefix("//") { return "https:" + raw }
        if raw.hasPrefix("/") { return SiteConfig.origin + raw }
        return raw
    }

    /// 打开播放页，催页面起播，把 hls.js 请求的 m3u8 地址截下来。
    ///
    /// 站点的播放地址不是接口直接返回的：先用 playback_source_id 换 token，
    /// 再由播放器向 provider 取分片，链接只出现在实际请求里。
    /// 抓到后就能交给 AVPlayer 原生播放，不再需要网页播放器。
    func resolveStream(path: String, cacheKey: String,
                       timeout: TimeInterval = 18) async -> String? {
        let key = cacheKey
        if let hit = streamCache[key], !hit.url.isEmpty,
           Date().timeIntervalSince(hit.at) < streamCacheTTL {
            return hit.url
        }

        // 预取和用户点播会同时触发解析，去重：同一个 key 只跑一次。
        // 否则隐藏 WebView 会被两次导航互相打乱，谁都不出结果。
        if let running = streamTask(for: key) {
            return await running.value
        }
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.doResolveStream(path: path, key: key, timeout: timeout)
        }
        setStreamTask(task, for: key)

        let result = await task.value
        clearStreamTask(for: key)
        return result
    }

    // 锁只在同步函数里取，避免 NSLock 在 async 上下文中的可用性告警
    private func streamTask(for key: String) -> Task<String?, Never>? {
        lock.lock(); defer { lock.unlock() }
        return streamTasks[key]
    }

    private func setStreamTask(_ t: Task<String?, Never>, for key: String) {
        lock.lock(); defer { lock.unlock() }
        streamTasks[key] = t
    }

    private func clearStreamTask(for key: String) {
        lock.lock(); defer { lock.unlock() }
        streamTasks[key] = nil
    }

    private func doResolveStream(path: String, key: String,
                                 timeout: TimeInterval) async -> String? {
        let start = Date()
        let soft = await softNavigate(path)
        if !soft {
            await hardLoad(SiteConfig.url(path), timeout: timeout)
        }

        // 页面要先把播放器挂上去，太早催没用
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let deadline = Date().addingTimeInterval(timeout)
        var rounds = 0
        while Date() < deadline {
            if let s = latestStream(since: start) {
                streamCache[key] = (s, Date())
                return s
            }
            rounds += 1
            _ = try? await evaluate(Self.triggerPlayJS)
            try? await Task.sleep(nanoseconds: 700_000_000)
            // 每 4 轮补一次整页加载，应对软跳转没触发路由的片子
            if rounds == 4 && soft {
                await hardLoad(SiteConfig.url(path), timeout: timeout)
            }
        }
        return nil
    }

    /// 催页面起播：直接 play 视频元素，不行就点带「播放」字样的按钮
    private static let triggerPlayJS = """
    (function(){
      try {
        var v = document.querySelector('video');
        if (v) {
          v.muted = true;
          var p = v.play();
          if (p && p.catch) { p.catch(function(){}); }
          return 'play';
        }
        var sels = ['[aria-label*="播放"]','[title*="播放"]','button','[role="button"]','[class*="play"]'];
        for (var i=0;i<sels.length;i++){
          var els = document.querySelectorAll(sels[i]);
          for (var j=0;j<els.length;j++){
            var t = (els[j].innerText || '').trim();
            var a = els[j].getAttribute('aria-label') || '';
            if (t.indexOf('播放') >= 0 || a.indexOf('播放') >= 0) {
              els[j].click();
              return 'click';
            }
          }
        }
        return 'none';
      } catch (e) { return 'err'; }
    })()
    """

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

      // 只上报地址、不上报内容：m3u8 是播放列表文本，原生端只需要 URL
      function postMedia(url) {
        try {
          window.webkit.messageHandlers.bpz.postMessage({ url: String(url), media: true });
        } catch (e) {}
        try {
          window.__bpzMedia = window.__bpzMedia || [];
          if (window.__bpzMedia.indexOf(String(url)) < 0) { window.__bpzMedia.push(String(url)); }
        } catch (e) {}
      }

      function isMedia(u) {
        var s = String(u || '');
        // 只认播放列表和整段视频；.ts 分片不要，抓到的会是几千个分片之一
        return /\\.m3u8(\\?|#|$)/i.test(s) || /\\.mp4(\\?|#|$)/i.test(s);
      }

      function want(url) {
        var u = String(url || '');
        return u.indexOf('/v1/') >= 0 || u.indexOf('/api/') >= 0;
      }

      var of = window.fetch;
      if (of) {
        window.fetch = function (input, init) {
          var url = (typeof input === 'string') ? input : (input && input.url) || '';
          if (isMedia(url)) { postMedia(url); }
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
        if (isMedia(u)) { postMedia(u); }
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
              let url = dict["url"] as? String else { return }

        // 媒体地址只要 URL，不解析内容
        if dict["media"] as? Bool == true {
            recordMedia(url)
            return
        }

        guard let text = dict["body"] as? String,
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
