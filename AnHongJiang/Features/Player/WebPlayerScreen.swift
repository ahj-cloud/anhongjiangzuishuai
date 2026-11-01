import SwiftUI
import WebKit

/// 站点播放页全屏内嵌。
///
/// 站点的播放地址不是直链：要先用 `playback_source_id` + `provider_id` 换 token，
/// 再由播放器运行时向 provider 请求分片，链路是个带验签的状态机，原生端复刻不现实。
/// 所以这里直接用一块独立的全屏 WKWebView 跑站点自己的播放器：
/// 画质切换、线路切换、字幕、倍速全部由页面负责，App 只提供全屏容器和退出。
struct WebPlayerScreen: View {
    let path: String
    let title: String
    let episode: String?

    @Environment(\.dismiss) private var dismiss
    @State private var chromeVisible = true

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            PlayerWebView(path: path)
                .ignoresSafeArea()

            if chromeVisible {
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let ep = episode, !ep.isEmpty {
                            Text(ep)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .statusBarHidden(false)
        .onAppear { OrientationManager.shared.landscape() }
        .onDisappear { OrientationManager.shared.portrait() }
    }
}

/// 独立的播放用 WebView。不复用 SiteEngine 那块，避免抓包导航和界面显示互相打断。
struct PlayerWebView: UIViewRepresentable {
    let path: String

    func makeUIView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()            // 复用 SiteEngine 已建立的 Cookie / 登录态
        conf.allowsInlineMediaPlayback = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.userContentController.addUserScript(
            WKUserScript(source: Self.autoPlayJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )

        let wv = WKWebView(frame: .zero, configuration: conf)
        wv.customUserAgent = SiteConfig.userAgent
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        wv.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) { wv.isInspectable = true }

        var req = URLRequest(url: SiteConfig.url(path))
        req.setValue(SiteConfig.userAgent, forHTTPHeaderField: "User-Agent")
        wv.load(req)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 页面渲染完再注入一次，应对 SPA 路由二次渲染
            webView.evaluateJavaScript(Self.retryJS, completionHandler: nil)
        }

        static let retryJS = """
        (function(){
          setTimeout(function(){
            var v = document.querySelector('video');
            if (!v) { return; }
            v.setAttribute('playsinline', '');
            v.setAttribute('webkit-playsinline', '');
            v.muted = true;                       // 静音才能绕过自动播放限制
            var p = v.play(); if (p && p.catch) { p.catch(function(){}); }
          }, 1200);
        })();
        """
    }

    /// 进页面后：静音自动起播、把播放器滚到视口顶部、压掉站点顶部导航占的高度
    private static let autoPlayJS = """
    (function(){
      var style = document.createElement('style');
      style.textContent = [
        'html,body{background:#000 !important;}',
        'body{overscroll-behavior:none;}'
      ].join('');
      (document.head || document.documentElement).appendChild(style);

      var tries = 0;
      var timer = setInterval(function(){
        tries++;
        var v = document.querySelector('video');
        if (v) {
          v.setAttribute('playsinline', '');
          v.setAttribute('webkit-playsinline', '');
          v.muted = true;
          var p = v.play();
          if (p && p.catch) { p.catch(function(){}); }
          try {
            var box = v.getBoundingClientRect();
            if (box.top > 40) { window.scrollBy(0, box.top - 8); }
          } catch (e) {}
          // 起播成功后放开声音，用户可以调音量
          if (!v.paused) {
            clearInterval(timer);
            v.muted = false;
          }
        }
        if (tries > 40) { clearInterval(timer); }
      }, 300);
    })();
    """
}
