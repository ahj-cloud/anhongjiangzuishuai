import SwiftUI
import WebKit

/// 原生渲染不到的页面（登录、活动页、特殊播放器）统一走这里，保证功能不缺项
struct WebFallbackView: View {
    let path: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SiteWebView(url: SiteConfig.url(path))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("网页版")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}

struct SiteWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()
        conf.allowsInlineMediaPlayback = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        let wv = WKWebView(frame: .zero, configuration: conf)
        wv.customUserAgent = SiteConfig.userAgent
        wv.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
