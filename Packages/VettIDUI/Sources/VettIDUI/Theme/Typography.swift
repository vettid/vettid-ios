import CoreText
import SwiftUI
import UIKit

/// The bundled faces, as on the website: Plus Jakarta Sans for headings, Inter
/// for body and UI text (both SIL OFL 1.1, `Resources/Fonts`). Each is one
/// variable font; its named weight instances are used by PostScript name.
public enum VettIDFonts {
    /// Registers the bundled fonts with the process, once.
    public static func register() { _ = registered }

    private static let registered: Bool = {
        let files = ["InterVariable", "PlusJakartaSans-Variable"]
        for name in files {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else {
                assertionFailure("missing font \(name)")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    enum Family { case heading, body }

    /// The PostScript name of [family] at [weight] (the weights the type scale uses; others fall back to regular).
    static func postScriptName(_ family: Family, _ weight: Font.Weight) -> String {
        let names = family == .heading ? headingFaces : bodyFaces
        return names[weight] ?? names[.regular] ?? ""
    }

    private static let headingFaces: [Font.Weight: String] = [
        .regular: "PlusJakartaSans-Regular",
        .medium: "PlusJakartaSans-Regular_Medium",
        .semibold: "PlusJakartaSans-Regular_SemiBold",
        .bold: "PlusJakartaSans-Regular_Bold",
        .heavy: "PlusJakartaSans-Regular_ExtraBold",
    ]

    private static let bodyFaces: [Font.Weight: String] = [
        .regular: "InterVariable",
        .medium: "InterVariable-Medium",
        .semibold: "InterVariable-SemiBold",
        .bold: "InterVariable-Bold",
        .heavy: "InterVariable-ExtraBold",
    ]
}

/// The type scale (vettid-android `core/ui/…/theme/Type.kt`): screen and section
/// titles in Plus Jakarta Sans, list rows, body and labels in Inter; sizes in
/// points as Android's in sp, scaled with Dynamic Type.
public enum VettIDTextStyle: CaseIterable, Sendable {
    case displaySmall, headlineMedium, headlineSmall
    case titleLarge, titleMedium, titleSmall
    case bodyLarge, bodyMedium, bodySmall
    case labelLarge, labelMedium, labelSmall

    struct Spec {
        let family: VettIDFonts.Family
        let weight: Font.Weight
        let size: CGFloat
        let lineHeight: CGFloat
        let relativeTo: Font.TextStyle
    }

    var spec: Spec {
        switch self {
        case .displaySmall: Spec(family: .heading, weight: .bold, size: 34, lineHeight: 40, relativeTo: .largeTitle)
        case .headlineMedium: Spec(family: .heading, weight: .bold, size: 28, lineHeight: 34, relativeTo: .title)
        case .headlineSmall: Spec(family: .heading, weight: .semibold, size: 24, lineHeight: 30, relativeTo: .title2)
        case .titleLarge: Spec(family: .heading, weight: .bold, size: 23, lineHeight: 28, relativeTo: .title2)
        case .titleMedium: Spec(family: .heading, weight: .bold, size: 19, lineHeight: 24, relativeTo: .title3)
        case .titleSmall: Spec(family: .body, weight: .semibold, size: 15, lineHeight: 20, relativeTo: .subheadline)
        case .bodyLarge: Spec(family: .body, weight: .regular, size: 16, lineHeight: 23, relativeTo: .body)
        case .bodyMedium: Spec(family: .body, weight: .regular, size: 14, lineHeight: 20, relativeTo: .subheadline)
        case .bodySmall: Spec(family: .body, weight: .regular, size: 12, lineHeight: 17, relativeTo: .caption)
        case .labelLarge: Spec(family: .body, weight: .medium, size: 16, lineHeight: 22, relativeTo: .body)
        case .labelMedium: Spec(family: .body, weight: .semibold, size: 13, lineHeight: 18, relativeTo: .footnote)
        case .labelSmall: Spec(family: .body, weight: .medium, size: 11, lineHeight: 16, relativeTo: .caption2)
        }
    }

    /// The style's font, with its own weight or [weight]; [size] overrides the
    /// point size (still scaled with Dynamic Type).
    public func font(weight: Font.Weight? = nil, size: CGFloat? = nil) -> Font {
        VettIDFonts.register()
        let s = spec
        return Font.custom(
            VettIDFonts.postScriptName(s.family, weight ?? s.weight),
            size: size ?? s.size,
            relativeTo: s.relativeTo
        )
    }
}

public extension VettIDTextStyle {
    /// The style as a UIKit font (for the UIKit text fields), scaled with Dynamic Type as ``font(weight:size:)`` is
    /// ([traits]: for a given size; default: the current one).
    func uiFont(weight: Font.Weight? = nil, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        VettIDFonts.register()
        let s = spec
        let base = UIFont(name: VettIDFonts.postScriptName(s.family, weight ?? s.weight), size: s.size)
            ?? .systemFont(ofSize: s.size)
        return UIFontMetrics(forTextStyle: s.relativeTo.uiTextStyle).scaledFont(for: base, compatibleWith: traits)
    }
}

private extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

/// Applies a ``VettIDTextStyle``: its font and the line height of the scale
/// (as extra line spacing, scaled with Dynamic Type).
struct VettIDTextStyleModifier: ViewModifier {
    let style: VettIDTextStyle
    let weight: Font.Weight?
    @ScaledMetric private var extraLeading: CGFloat

    init(style: VettIDTextStyle, weight: Font.Weight?) {
        self.style = style
        self.weight = weight
        let spec = style.spec
        // Inter and Plus Jakarta Sans set about 1.21 × the size by default.
        _extraLeading = ScaledMetric(wrappedValue: max(0, spec.lineHeight - spec.size * 1.21), relativeTo: spec.relativeTo)
    }

    func body(content: Content) -> some View {
        content
            .font(style.font(weight: weight))
            .lineSpacing(extraLeading)
    }
}

public extension View {
    /// Sets the text style of the VettID type scale (vettid-android `MaterialTheme.typography.*`).
    func vettIDFont(_ style: VettIDTextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(VettIDTextStyleModifier(style: style, weight: weight))
    }
}
