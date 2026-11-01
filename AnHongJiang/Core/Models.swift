import Foundation

// MARK: - 基础模型

struct MediaItem: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var poster: String?
    var remark: String?
    var year: String?
    var area: String?
    var category: String?
    var score: String?
    var summary: String?
    /// 站内路由，形如 /player/av_xxx
    var route: String?

    var posterURL: URL? { poster.flatMap { URL(string: Self.absolute($0)) } }

    /// 站内返回的图片有相对路径也有协议相对路径，统一补全
    static func absolute(_ raw: String) -> String {
        if raw.hasPrefix("//") { return "https:" + raw }
        if raw.hasPrefix("/") { return SiteConfig.origin + raw }
        return raw
    }

    /// 详情页统一入口：优先 route，其次 id 推导
    var detailRoute: String {
        if let r = route, !r.isEmpty { return r }
        return "/player/\(id)"
    }
}

struct FeedSection: Identifiable, Hashable {
    var id: String
    var title: String
    var items: [MediaItem]
}

struct HomeFeed {
    var hero: [MediaItem]
    var sections: [FeedSection]
}

struct Episode: Identifiable, Hashable {
    var id: String
    var name: String
    var url: String?
    var route: String?
}

struct DetailPayload {
    var item: MediaItem
    var episodes: [Episode]
    var sources: [PlaybackSource]
    var related: [MediaItem]
}

struct PlaybackSource: Identifiable, Hashable {
    var id: String { url }
    var url: String
    var quality: String
    var isHLS: Bool { url.contains(".m3u8") || url.contains("/hls/") }
}

// MARK: - 站点配置

enum SiteConfig {
    /// 换域名只改这一行
    static let origin = "https://bpz3.com"
    static let homePath = "/"
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    static var homeURL: URL { URL(string: origin + homePath)! }
    static func url(_ path: String) -> URL {
        if path.hasPrefix("http") { return URL(string: path) ?? homeURL }
        return URL(string: origin + path) ?? homeURL
    }
}

// MARK: - 响应归一化
//
// 站点接口的字段名没有公开文档，且随版本变动，这里用特征匹配把任意层级的 JSON
// 归一到 MediaItem。匹配失败的字段留空，不影响列表渲染。

enum FeedParser {

    private static let titleKeys = ["title", "name", "vod_name", "video_name", "movie_name",
                                    "cn_name", "display_name", "caption", "series_name"]
    private static let posterKeys = ["poster", "poster_url", "cover", "cover_url", "image",
                                     "image_url", "img", "pic", "pic_url", "thumbnail", "thumb",
                                     "vertical_poster", "horizontal_poster", "backdrop", "still"]
    private static let idKeys = ["id", "av_id", "video_id", "movie_id", "subject_id", "slug",
                                 "key", "uid", "code", "resource_id"]
    private static let remarkKeys = ["remark", "note", "subtitle", "update_note", "episode_note",
                                     "status_text", "episode_text", "latest_episode", "update_info",
                                     "extra", "tag"]
    private static let yearKeys = ["year", "release_year", "pub_year", "year_text"]
    private static let areaKeys = ["area", "region", "country", "countries", "area_text"]
    private static let scoreKeys = ["score", "rating", "douban_score", "vote_average", "star"]
    private static let categoryKeys = ["category", "type", "type_name", "channel", "genre", "kind"]
    private static let summaryKeys = ["summary", "description", "intro", "overview", "plot", "desc"]
    private static let routeKeys = ["url", "link", "href", "path", "detail_url", "share_url"]

    private static let heroKeys = ["banner", "hero", "featured", "top", "spotlight", "carousel",
                                   "recommend_banner", "headline"]

    // MARK: 入口

    static func home(from json: Any) -> HomeFeed {
        var hero: [MediaItem] = []
        var sections: [FeedSection] = []
        var seenSectionKeys = Set<String>()

        walk(json, path: []) { dict, path in
            for (key, value) in dict {
                guard let arr = value as? [Any] else { continue }
                let items = mediaItems(in: arr)
                guard items.count >= 3 else { continue }

                if heroKeys.contains(key.lowercased()), hero.isEmpty {
                    hero = Array(items.prefix(8))
                    continue
                }
                // 同级 dict 自带标题时用它，否则用 key 兜底
                let label = firstString(dict, titleKeys).flatMap { $0.count <= 12 ? $0 : nil }
                    ?? humanize(key)
                let sid = path.joined(separator: ".") + "." + key
                guard seenSectionKeys.insert(sid).inserted else { continue }
                sections.append(FeedSection(id: sid, title: label, items: Array(items.prefix(24))))
            }
        }

        if hero.isEmpty {
            hero = Array((sections.first?.items ?? []).prefix(6))
        }
        // 按条目数量排序，主栏目靠前
        sections.sort { $0.items.count > $1.items.count }
        return HomeFeed(hero: hero, sections: sections)
    }

    static func items(from json: Any) -> [MediaItem] {
        if let arr = json as? [Any] { return mediaItems(in: arr) }
        var found: [MediaItem] = []
        walk(json, path: []) { dict, _ in
            for (_, value) in dict {
                if let arr = value as? [Any] {
                    let nested = mediaItems(in: arr)
                    if nested.count > found.count { found = nested }
                }
            }
        }
        return found
    }

    static func detail(from json: Any, fallback: MediaItem) -> DetailPayload {
        let flat = flatten(json)
        var item = fallback

        // 用字段最全的那个 dict 补全详情元信息
        let richest = flat.max { $0.count < $1.count }
        if let node = richest {
            if item.summary == nil { item.summary = firstString(node, summaryKeys) }
            if item.year == nil { item.year = firstString(node, yearKeys) }
            if item.area == nil { item.area = firstString(node, areaKeys) }
            if item.score == nil { item.score = firstString(node, scoreKeys) }
            if item.poster == nil { item.poster = firstString(node, posterKeys) }
            if item.remark == nil { item.remark = firstString(node, remarkKeys) }
            if item.category == nil { item.category = firstString(node, categoryKeys) }
        }

        var episodes: [Episode] = []
        for node in flat {
            for (key, value) in node {
                guard let arr = value as? [Any], !arr.isEmpty else { continue }
                let eps = episodeList(in: arr, key: key)
                if eps.count > episodes.count { episodes = eps }
            }
        }
        // 单集影片：无选集时给一个“正片”条目
        if episodes.isEmpty {
            episodes = [Episode(id: "main", name: "正片", url: nil, route: fallback.detailRoute)]
        }

        let sources = playbackSources(in: json)
        let related = relatedItems(from: json, excluding: fallback.id)
        return DetailPayload(item: item, episodes: episodes, sources: sources, related: related)
    }

    static func playbackSources(in json: Any) -> [PlaybackSource] {
        var out: [PlaybackSource] = []
        var seen = Set<String>()
        func add(_ raw: String, _ quality: String) {
            let s = MediaItem.absolute(raw)
            guard s.hasPrefix("http"), !seen.contains(s) else { return }
            guard s.contains(".m3u8") || s.contains(".mp4") || s.contains("/hls/") || s.contains("playlist") else { return }
            seen.insert(s)
            out.append(PlaybackSource(url: s, quality: quality))
        }
        for node in flatten(json) {
            for (key, value) in node {
                if let s = value as? String, [".m3u8", ".mp4", "/hls/"].contains(where: { s.contains($0) }) {
                    add(s, qualityLabel(for: node, key: key))
                }
            }
        }
        return out.sorted { $0.quality < $1.quality }
    }

    // MARK: 内部

    private static func mediaItems(in array: [Any]) -> [MediaItem] {
        var out: [MediaItem] = []
        var seen = Set<String>()
        for raw in array {
            guard let dict = raw as? [String: Any] else { continue }
            guard let item = mediaItem(from: dict) else { continue }
            guard seen.insert(item.id).inserted else { continue }
            out.append(item)
        }
        return out
    }

    private static func mediaItem(from dict: [String: Any]) -> MediaItem? {
        let title = firstString(dict, titleKeys)
        let poster = firstString(dict, posterKeys)
        var route = firstString(dict, routeKeys).flatMap { $0.contains("/player/") || $0.hasPrefix("/") ? $0 : nil }
        var id = firstString(dict, idKeys)

        // 从任意字符串里挖 av_ 开头的资源 id
        if id == nil || !id!.hasPrefix("av_") {
            if let av = findAvToken(in: dict) { id = av }
        }
        if route == nil, let av = id, av.hasPrefix("av_") { route = "/player/\(av)" }

        guard let t = title, !t.isEmpty, t.count <= 60 else { return nil }
        guard poster != nil || id?.hasPrefix("av_") == true else { return nil }

        return MediaItem(
            id: id ?? t,
            title: t,
            poster: poster,
            remark: firstString(dict, remarkKeys),
            year: firstString(dict, yearKeys),
            area: firstString(dict, areaKeys),
            category: firstString(dict, categoryKeys),
            score: firstString(dict, scoreKeys),
            summary: firstString(dict, summaryKeys),
            route: route
        )
    }

    private static func episodeList(in array: [Any], key: String) -> [Episode] {
        var out: [Episode] = []
        for (idx, raw) in array.enumerated() {
            if let dict = raw as? [String: Any] {
                let name = firstString(dict, ["name", "episode_name", "title", "episode", "ep", "label"])
                    ?? "第\(idx + 1)集"
                let url = firstString(dict, ["url", "play_url", "hls", "m3u8", "src", "video_url"])
                    .flatMap { $0.hasPrefix("http") ? $0 : nil }
                let route = firstString(dict, ["route", "path", "href", "link"])
                out.append(Episode(id: "\(key)-\(idx)", name: name, url: url, route: route))
            } else if let s = raw as? String, s.hasPrefix("http") {
                out.append(Episode(id: "\(key)-\(idx)", name: "第\(idx + 1)集", url: s, route: nil))
            }
        }
        // 只有一两个字符串的数组多半不是选集
        return out.count >= 1 && (array.count > 1 || key.lowercased().contains("ep")) ? out : []
    }

    private static func relatedItems(from json: Any, excluding id: String) -> [MediaItem] {
        var best: [MediaItem] = []
        for node in flatten(json) {
            for (_, value) in node {
                guard let arr = value as? [Any] else { continue }
                let items = mediaItems(in: arr).filter { $0.id != id }
                if items.count > best.count { best = items }
            }
        }
        return Array(best.prefix(18))
    }

    private static func flatten(_ json: Any) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func rec(_ node: Any, depth: Int) {
            guard depth < 8 else { return }
            if let dict = node as? [String: Any] {
                out.append(dict)
                for (_, v) in dict { rec(v, depth: depth + 1) }
            } else if let arr = node as? [Any] {
                for v in arr { rec(v, depth: depth + 1) }
            }
        }
        rec(json, depth: 0)
        return out
    }

    private static func walk(_ node: Any, path: [String], visit: ([String: Any], [String]) -> Void) {
        guard path.count < 6 else { return }
        if let dict = node as? [String: Any] {
            visit(dict, path)
            for (k, v) in dict { walk(v, path: path + [k], visit: visit) }
        } else if let arr = node as? [Any] {
            for (i, v) in arr.enumerated() { walk(v, path: path + ["[\(i)]"], visit: visit) }
        }
    }

    private static func firstString(_ dict: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let s = dict[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let n = dict[k] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    private static func findAvToken(in dict: [String: Any]) -> String? {
        for (_, v) in dict {
            if let s = v as? String, let r = s.range(of: "av_[A-Za-z0-9_-]{10,}") {
                return String(s[r])
            }
        }
        return nil
    }

    private static func qualityLabel(for node: [String: Any], key: String) -> String {
        if let q = firstString(node, ["quality", "definition", "resolution", "label", "name"]) { return q }
        if key.contains("1080") { return "1080P" }
        if key.contains("720") { return "720P" }
        return "自动"
    }

    private static func humanize(_ key: String) -> String {
        let map = ["tv": "电视剧", "movie": "电影", "anime": "动漫", "variety": "综艺",
                   "documentary": "纪录片", "short": "短剧", "list": "推荐", "items": "推荐",
                   "data": "推荐", "result": "结果", "latest": "最近更新", "hot": "热播"]
        let lower = key.lowercased()
        for (k, v) in map where lower.contains(k) { return v }
        return "推荐"
    }
}
