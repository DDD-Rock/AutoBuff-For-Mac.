import SwiftUI

struct AppTheme {
    static let background = Color(red: 0.955, green: 0.969, blue: 0.992)
    static let panel = Color.white
    static let accent = Color(red: 0.075, green: 0.435, blue: 0.965)
    static let accentSoft = Color(red: 0.925, green: 0.956, blue: 1.0)
    static let textPrimary = Color(red: 0.09, green: 0.12, blue: 0.19)
    static let textSecondary = Color(red: 0.43, green: 0.47, blue: 0.55)
    static let border = Color(red: 0.89, green: 0.91, blue: 0.95)
    static let danger = Color(red: 0.91, green: 0.25, blue: 0.29)
    static let success = Color(red: 0.10, green: 0.67, blue: 0.40)
    static let warning = Color(red: 0.93, green: 0.57, blue: 0.10)
}

struct AppCardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(AppTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 12, y: 4)
    }
}

extension View {
    func appCard(padding: CGFloat = 16) -> some View {
        modifier(AppCardModifier(padding: padding))
    }
}
