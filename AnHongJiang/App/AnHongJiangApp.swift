import SwiftUI
import UIKit

@main
struct AnHongJiangApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library = LibraryStore()

    init() {
        // 启动即预热数据引擎，首页秒开
        _ = SiteEngine.shared
        UITabBar.appearance().unselectedItemTintColor = UIColor.secondaryLabel
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(library)
                .tint(Theme.brand)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationManager.shared.mask
    }
}

struct RootTabView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(0)

            BrowseView()
                .tabItem { Label("频道", systemImage: "square.grid.2x2.fill") }
                .tag(1)

            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(2)

            LibraryView()
                .tabItem { Label("我的", systemImage: "person.fill") }
                .tag(3)
        }
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}
