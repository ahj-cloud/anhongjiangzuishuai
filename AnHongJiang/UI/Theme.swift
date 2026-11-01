import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum Theme {
    /// 品牌橙，跟腾讯视频的主色接近但不照抄
    static let brand = Color(hex: 0xFF6A00)
    static let brandDeep = Color(hex: 0xE23A00)

    static let bg = Color(light: Color(hex: 0xF6F6F8), dark: Color(hex: 0x0C0D10))
    static let card = Color(light: .white, dark: Color(hex: 0x17181D))
    static let text = Color(light: Color(hex: 0x111114), dark: Color(hex: 0xF2F2F5))
    static let subtext = Color(light: Color(hex: 0x8A8A94), dark: Color(hex: 0x9A9AA4))
    static let hairline = Color(light: Color(hex: 0xE8E8EE), dark: Color(hex: 0x26272E))

    static let radius: CGFloat = 10
    static let pagePadding: CGFloat = 14
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

// MARK: - 通用组件

struct LoadingView: View {
    var text: String = "加载中"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.brand)
            Text(text).font(.footnote).foregroundStyle(Theme.subtext)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.subtext)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.subtext)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let retry {
                Button("重试", action: retry)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22).padding(.vertical, 8)
                    .background(Theme.brand, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SectionHeader: View {
    let title: String
    var more: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            if let more {
                Button(action: more) {
                    HStack(spacing: 2) {
                        Text("更多").font(.caption)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Theme.subtext)
                }
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }
}

struct ScoreTag: View {
    let score: String

    var body: some View {
        Text(score)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.brand)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}
