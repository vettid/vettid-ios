import Foundation

/// WCAG 2.x relative luminance of an opaque colour.
public func relativeLuminance(_ color: ThemeColor) -> Double {
    func channel(_ v: Double) -> Double {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
}

/// WCAG 2.x contrast ratio between two opaque colours (1.0 – 21.0).
public func contrastRatio(_ a: ThemeColor, _ b: ThemeColor) -> Double {
    let la = relativeLuminance(a)
    let lb = relativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}
