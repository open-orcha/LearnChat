import SwiftUI
import UIKit

/// The Android app's Material 3 colour scheme (Indigo primary, teal secondary), as light/dark
/// dynamic colours so every screen matches the Compose theme in both appearances.
enum LearnChatTheme {
    // Brand
    static let primary = Color(light: 0x3F51B5, dark: 0x9FA8DA)          // Indigo / IndigoDark
    static let onPrimary = Color(light: 0xFFFFFF, dark: 0x0A1A63)
    static let primaryContainer = Color(light: 0xDEE0FF, dark: 0x263A9E)
    static let onPrimaryContainer = Color(light: 0x00105C, dark: 0xDEE0FF)
    static let secondary = Color(light: 0x00838F, dark: 0x7CE0FF)        // teal / Sky
    static let tertiary = Color(light: 0x6A1B9A, dark: 0xCE93D8)

    // Surfaces (Material 3 neutral tonal palette)
    static let surface = Color(light: 0xFEF7FF, dark: 0x141218)
    static let surfaceContainerLowest = Color(light: 0xFFFFFF, dark: 0x0F0D13)
    static let surfaceContainerLow = Color(light: 0xF7F2FA, dark: 0x1D1B20)
    static let surfaceContainer = Color(light: 0xF3EDF7, dark: 0x211F26)
    static let surfaceContainerHigh = Color(light: 0xECE6F0, dark: 0x2B2930)
    static let surfaceContainerHighest = Color(light: 0xE6E0E9, dark: 0x36343B)
    static let onSurface = Color(light: 0x1D1B20, dark: 0xE6E0E9)
    static let onSurfaceVariant = Color(light: 0x49454F, dark: 0xCAC4D0)
    static let outline = Color(light: 0x79747E, dark: 0x938F99)
    static let outlineVariant = Color(light: 0xCAC4D0, dark: 0x49454F)

    // Error
    static let error = Color(light: 0xB3261E, dark: 0xF2B8B5)
    static let errorContainer = Color(light: 0xF9DEDC, dark: 0x8C1D18)
    static let onErrorContainer = Color(light: 0x410E0B, dark: 0xF9DEDC)

    // Snackbar (Material inverse surface)
    static let inverseSurface = Color(light: 0x322F35, dark: 0xE6E0E9)
    static let inverseOnSurface = Color(light: 0xF5EFF7, dark: 0x322F35)

    /// Card corner radius (Material medium shape).
    static let cardRadius: CGFloat = 12
}

extension Color {
    /// A colour that follows the system appearance, like Compose's light/dark colour schemes.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Material 3 type scale mapped onto SwiftUI text styles.
enum LearnChatType {
    static let titleMedium = Font.system(size: 16, weight: .medium)
    static let titleLarge = Font.system(size: 22, weight: .regular)
    static let bodyLarge = Font.system(size: 16)
    static let bodyMedium = Font.system(size: 14)
    static let bodySmall = Font.system(size: 12)
    static let labelLarge = Font.system(size: 14, weight: .medium)
    static let labelMedium = Font.system(size: 12, weight: .medium)
    static let labelSmall = Font.system(size: 11, weight: .medium)
}
