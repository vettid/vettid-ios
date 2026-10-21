#if os(iOS)
import Photos
import SwiftUI
import UIKit
import VettIDData
import VettIDMedia
import VettIDMessages
import VettIDUI

/// The photo viewer (ANDROID-PLAN "Photo attachments", "Viewing"): out of screenshots and recordings while open unless
/// "Allow screenshots" is on (the app-switcher cover and capture hiding always), zoom, Save to phone and Share, each after
/// the warning that the photo then leaves VettID. The photo is decoded to the screen's size from memory, after its type
/// and bounds are checked. Mirrors vettid-android `PhotoViewerScreen`.
public struct PhotoViewerScreen: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: PhotoViewerState
    let onBack: @MainActor () -> Void
    let onRetry: @MainActor () -> Void
    @State private var decoded: UIImage?
    @State private var undecodable = false
    @State private var confirm: LeaveAction?
    @State private var notice: String?
    @State private var sharing: SharedPhotoItem?

    /// The long edge a photo is decoded to: about a phone screen's in pixels, and a sent photo's own (chosen; not in the
    /// spec: vettid-android decodes to the window's size).
    static let edge = PhotoLimits.sendLongEdge

    enum LeaveAction: Identifiable {
        case save, share
        var id: Self { self }
    }

    public init(state: PhotoViewerState, onBack: @escaping @MainActor () -> Void, onRetry: @escaping @MainActor () -> Void) {
        self.state = state
        self.onBack = onBack
        self.onRetry = onRetry
    }

    public var body: some View {
        DetailScaffold(onBack: onBack) {
            PhotoSecure { content.frame(maxWidth: .infinity, maxHeight: .infinity) }
        } overlay: {
            if let notice {
                Text(notice).vettIDFont(.bodyMedium).padding(Spacing.l).accessibilityIdentifier("photo_notice")
            }
        } actions: {
            if state.photo != nil {
                IconButton(.download, label: MessagesStrings.photoSave) { confirm = .save }.accessibilityIdentifier("photo_save")
                IconButton(.share, label: MessagesStrings.photoShare) { confirm = .share }.accessibilityIdentifier("photo_share")
            }
        }
        .confirmDialog(
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
            title: confirm == .share ? MessagesStrings.photoShare : MessagesStrings.photoSave,
            message: MessagesStrings.photoLeaves,
            confirmLabel: MessagesStrings.photoContinue,
            onConfirm: leave
        )
        .sheet(item: $sharing) { item in ShareSheet(item: item).ignoresSafeArea() }
        .task(id: state.photo.map(ObjectIdentifier.init)) { await decode() }
        .accessibilityIdentifier("photo_viewer")
    }

    @ViewBuilder private var content: some View {
        if let error = state.error {
            VStack {
                NoticeCard(.warning, title: MessagesStrings.errorTitle, message: problemText ?? error.message(timeScale: timeScale)) {
                    Button(MessagesStrings.retry, action: onRetry).accessibilityIdentifier("photo_retry")
                }
                .padding(Spacing.xl)
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("photo_error")
        } else if let decoded {
            ZoomableImage(image: decoded, name: state.name)
        } else if undecodable {
            Text(MessagesStrings.photoInType).vettIDFont(.bodyLarge).multilineTextAlignment(.center).padding(Spacing.xl)
                .frame(maxHeight: .infinity)
        } else {
            ProgressView().tint(colors.primary.color).frame(maxHeight: .infinity)
        }
    }

    private var problemText: String? {
        switch state.problem {
        case .type: MessagesStrings.photoInType
        case .bad: MessagesStrings.photoBad
        case .unavailable: MessagesStrings.photoUnavailable
        case .busy: MessagesStrings.photoBusy
        case nil: nil
        }
    }

    private func decode() async {
        decoded = nil
        undecodable = false
        guard let photo = state.photo else { return }
        decoded = await PhotoImages.received(photo.bytes.copy(), edge: Self.edge)
        undecodable = decoded == nil
    }

    /// "Continue": a photo wiped by a clear (a lock, the hold) is not a photo any more, and nothing leaves VettID then.
    private func leave() {
        let action = confirm
        confirm = nil
        guard let photo = state.photo, photo.intact else {
            notice = MessagesStrings.photoSaveFailed
            return
        }
        switch action {
        case .save:
            // A copy: a clear while the write runs must not turn the saved photo into zeros.
            let copy = photo.bytes.copy()
            Task {
                notice = await PhotoExport.save(copy, type: photo.type) ? MessagesStrings.photoSaved : MessagesStrings.photoSaveFailed
            }
        case .share:
            notice = nil
            sharing = SharedPhotoItem(token: SharedPhotos.shared.offer(photo.bytes.copy(), type: photo.type), type: photo.type)
        case nil:
            break
        }
    }
}

/// The photo with pinch to zoom (1 to 5 times) and a drag while zoomed, and the sender's name under it.
private struct ZoomableImage: View {
    let image: UIImage
    let name: String?
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var start: CGSize = .zero

    static let maxZoom: CGFloat = 5

    var body: some View {
        VStack(spacing: 0) {
            Image(uiImage: image).resizable().scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .gesture(zoom.simultaneously(with: pan))
                .accessibilityLabel(MessagesStrings.photoViewerCd)
            if let name { Text(name).vettIDFont(.bodySmall).padding(Spacing.m) }
        }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { scale = min(max(base * $0.magnification, 1), Self.maxZoom) }
            .onEnded { _ in
                base = scale
                if scale == 1 { offset = .zero; start = .zero }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { v in
                guard scale > 1 else { return }
                offset = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
            }
            .onEnded { _ in start = offset }
    }
}

/// Save to phone and Share (ANDROID-PLAN "Saving and sharing leave VettID"; IOS-PLAN §4: saving uses the add-only
/// permission, and only after the warning). Save adds the bytes to the Photos library from memory, named
/// `VettID_<yyyyMMdd_HHmmss>` with the sniffed type's extension; Share hands them to the chosen app through the share
/// sheet, read from ``SharedPhotos`` only while offered (nothing once the vault locks or the viewer goes).
enum PhotoExport {
    static func fileName(_ type: ImageType, at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "VettID_\(f.string(from: date)).\(type.fileExtension)"
    }

    static func save(_ bytes: [UInt8], type: ImageType) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        let data = Data(bytes)
        let name = fileName(type)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = name
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
            }
            return true
        } catch {
            return false
        }
    }
}

/// One share of a photo: the share sheet asks for its bytes by token when the chosen app reads them.
final class SharedPhotoItem: NSObject, Identifiable, UIActivityItemSource, @unchecked Sendable {
    let token: String
    let type: ImageType

    init(token: String, type: ImageType) {
        self.token = token
        self.type = type
    }

    var id: String { token }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { Data() }

    /// The bytes while offered; nothing once withdrawn (a lock, the viewer gone).
    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        SharedPhotos.shared.data(token)
    }

    func activityViewController(
        _ controller: UIActivityViewController, dataTypeIdentifierForActivityType type: UIActivity.ActivityType?
    ) -> String {
        self.type.uti
    }
}

/// The system share sheet for one offered photo.
private struct ShareSheet: UIViewControllerRepresentable {
    let item: SharedPhotoItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
