import SwiftUI

/// A sheet of options that opens at half height and can be pulled to full height, its content scrolling: at the larger
/// text sizes its last option (or Cancel) would otherwise sit below the sheet's edge, out of reach.
public enum VettIDSheet {
    /// The heights a sheet of options offers: half, and full for the larger text sizes.
    public static let detents: Set<PresentationDetent> = [.medium, .large]
}

public extension View {
    /// Wraps a sheet's content so that it scrolls when it does not fit (it does not bounce when it fits), and offers the
    /// sheet's half and full heights with a drag indicator (``VettIDSheet/detents``).
    func vettIDGrowingSheet() -> some View {
        ScrollView { self }
            .scrollBounceBehavior(.basedOnSize)
            .presentationDetents(VettIDSheet.detents)
            .presentationDragIndicator(.visible)
    }
}
