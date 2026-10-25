import SwiftUI

enum GradientAppTheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light:
            return "Светлая"
        case .dark:
            return "Тёмная"
        }
    }

    var shaderValue: CGFloat {
        self == .dark ? 1 : 0
    }
}

enum GradientColorPreset: String, CaseIterable, Identifiable {
    case blue
    case yellow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue:
            return "Синий"
        case .yellow:
            return "Жёлтый"
        }
    }

    var shaderIndex: CGFloat {
        switch self {
        case .blue:
            return 0
        case .yellow:
            return 3
        }
    }

    var swatch: Color {
        switch self {
        case .blue:
            return Color(red: 0.26, green: 0.55, blue: 0.98)
        case .yellow:
            return Color(red: 1.0, green: 0.7, blue: 0.0)
        }
    }

    var darkMaskTint: Color {
        switch self {
        case .blue:
            return Color(red: 0.008, green: 0.036, blue: 0.115)
        case .yellow:
            return Color(red: 0.105, green: 0.060, blue: 0.008)
        }
    }
}
