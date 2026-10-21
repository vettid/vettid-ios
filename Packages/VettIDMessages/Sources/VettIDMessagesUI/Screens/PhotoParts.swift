#if os(iOS)
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import VettIDData
import VettIDMedia
import VettIDMessages
import VettIDUI

/// What the photo parts of a conversation can ask for. Mirrors vettid-android `PhotoActions`.
public struct PhotoActions {
    public var onTakePhoto: @MainActor () -> Void = {}
    /// One reader per picked picture, read (into memory) and prepared one at a time.
    public var onPicked: @MainActor ([ConversationViewModel.PhotoSource]) -> Void = { _ in }
    /// A shot from the camera, encoded in memory.
    public var onShot: @MainActor ([UInt8]) -> Void = { _ in }
    public var onCloseCamera: @MainActor () -> Void = {}
    public var onCaption: @MainActor (String) -> Void = { _ in }
    public var onSend: @MainActor () -> Void = {}
    public var onCancel: @MainActor () -> Void = {}
    public var onDismissProblem: @MainActor () -> Void = {}
    /// The viewer of a message's photo.
    public var onOpen: @MainActor (String) -> Void = { _ in }
    public var thumbnail: @MainActor (String) async -> [UInt8]? = { _ in nil }

    public init() {}
}

/// The composer's photo button (ANDROID-PLAN "Photo attachments", "Choosing a photo"): "Take a photo" (the app's own
/// camera) or "Choose photos" (the system's Photos picker, at most 10, images only: it runs outside the app, which asks
/// for no photo-library permission and receives only what the member picks, IOS-PLAN §4). The picked pictures are read
/// into memory only. Mirrors vettid-android `PhotoButton`.
struct PhotoButton: View {
    @Environment(\.vettIDColors) private var colors
    let enabled: Bool
    let actions: PhotoActions
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button(action: actions.onTakePhoto) { Label(MessagesStrings.photoTake, systemImage: VettIDSymbol.photoCamera.rawValue) }
            Button { picking = true } label: { Label(MessagesStrings.photoChoose, systemImage: VettIDSymbol.image.rawValue) }
        } label: {
            VettIDSymbol.image.image.font(.system(size: 20)).foregroundStyle(colors.onSurfaceVariant)
                .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
        }
        .disabled(!enabled)
        .accessibilityLabel(MessagesStrings.photoAdd)
        .accessibilityIdentifier("photo")
        .photosPicker(
            isPresented: $picking, selection: $picked, maxSelectionCount: PhotoDraft.maxPhotos, matching: .images,
            preferredItemEncoding: .compatible
        )
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            actions.onPicked(items.map(PickedPhotos.reader))
        }
    }
}

/// Reading a picked picture into memory: the picker's data, at most ``PhotoLimits/sourceMaxBytes`` (a larger one is a
/// pick that could not be used), never a file of the app's.
enum PickedPhotos {
    static func reader(_ item: PhotosPickerItem) -> ConversationViewModel.PhotoSource {
        {
            guard let data = try? await item.loadTransferable(type: Data.self), data.count <= PhotoLimits.sourceMaxBytes else { return nil }
            return [UInt8](data)
        }
    }
}

/// What a screen reader says for a photo message: "Photo you sent" or "Photo from {name}", then the caption and the
/// state, each only when there is one ("Photo you sent. Delivered", never "Photo you sent. . Delivered"). Mirrors
/// vettid-android `photoLabel`.
func photoLabel(_ head: String, _ caption: String?, _ status: String?) -> String {
    [head, caption, status].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        .joined(separator: ". ")
}

/// The bubble's line in words, with the connection's [name] where it says it.
func photoStatusText(_ s: PhotoStatus, _ name: String) -> String {
    switch s.text {
    case .peerNoPhotos: MessagesStrings.photoPeerNoPhotos(name)
    case .inRate: MessagesStrings.photoInRate(name)
    case .inWithdrawn: MessagesStrings.photoInWithdrawn(name)
    default: plainStatusText(s.text)
    }
}

/// The lines that name nobody.
private func plainStatusText(_ t: PhotoStatus.Text) -> String {
    let texts: [PhotoStatus.Text: String] = [
        .sending: MessagesStrings.photoSending, .delivered: MessagesStrings.photoDelivered,
        .receiving: MessagesStrings.photoReceiving, .notSentBubble: MessagesStrings.photoNotSentBubble,
        .unconfirmed: MessagesStrings.photoUnconfirmed, .notDelivered: MessagesStrings.photoNotDelivered,
        .inFull: MessagesStrings.photoInFull, .inType: MessagesStrings.photoInType, .inNever: MessagesStrings.photoInNever,
    ]
    return texts[t] ?? ""
}

/// A problem with a photo in the plan's words.
func photoProblemText(_ p: PhotoProblem) -> String {
    switch p {
    case .tooLarge: MessagesStrings.photoTooLarge
    case .unsupported: MessagesStrings.photoUnsupported
    case .unreadable: MessagesStrings.photoUnreadable
    case .mailboxFull: MessagesStrings.photoMailboxFull
    case .vaultFull: MessagesStrings.photoVaultFull
    case .noAnswer: MessagesStrings.photoNoAnswer
    case .notSent: MessagesStrings.photoNotSent
    }
}

/// Decoded pictures for showing, from memory, off the main actor: every received photo and thumbnail through
/// ``Photos/decodeReceived(_:targetLongEdge:maxSide:maxPixels:)`` (sniffed, bounded, first frame only).
enum PhotoImages {
    static func thumbnail(_ bytes: [UInt8]) async -> UIImage? {
        await Task.detached { (try? Photos.decodeThumbnail(bytes)).map { UIImage(cgImage: $0) } }.value
    }

    static func received(_ bytes: [UInt8], edge: Int) async -> UIImage? {
        await Task.detached { (try? Photos.decodeReceived(bytes, targetLongEdge: edge)).map { UIImage(cgImage: $0) } }.value
    }

    /// The member's own shot, for "Retake" or "Use photo": decoded with its orientation, to the screen's size.
    static func shot(_ bytes: [UInt8], edge: Int) async -> UIImage? {
        await Task.detached {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, options) else { return nil }
            let thumb = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
            ] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(src, 0, thumb).map { UIImage(cgImage: $0) }
        }.value
    }
}

/// A photo message (ANDROID-PLAN "The bubble"): the thumbnail (from memory, or fetched as it is shown), decoded only
/// after the type and the header's bounds (1,024 a side) are checked; a neutral placeholder sized from the claimed
/// `width` and `height`, clamped, until then; the caption under it; the state. Mirrors vettid-android `PhotoBubble`.
struct PhotoBubble: View {
    @Environment(\.vettIDColors) private var colors
    let message: MessageInfo
    let name: String
    let generation: Int
    let actions: PhotoActions
    let onDelete: @MainActor () -> Void
    @State private var thumb: UIImage?

    static let width: CGFloat = 240
    static let minRatio: CGFloat = 0.5
    static let maxRatio: CGFloat = 2

    /// The placeholder's width over height: the sender's claim within 1–8,192 a side, clamped; square otherwise.
    static func ratio(_ a: AttachmentInfo) -> CGFloat {
        let side = 1...PhotoLimits.viewMaxSide
        guard side.contains(a.width), side.contains(a.height) else { return 1 }
        return min(max(CGFloat(a.width) / CGFloat(a.height), minRatio), maxRatio)
    }

    var body: some View {
        if let a = message.attachment {
            let status = PhotoStatus.of(a, outgoing: message.outgoing)
            let statusText = status.map { photoStatusText($0, name) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: Spacing.xxs) {
                picture(a, statusText)
                if !message.text.isEmpty {
                    Text(message.text).vettIDFont(.bodyLarge).accessibilityHidden(true)
                }
                if let statusText {
                    Text(statusText).vettIDFont(.labelSmall)
                        .foregroundStyle(status?.failed == true ? colors.error : colors.onSurfaceVariant)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.xxs)
            .contextMenu { Button(MessagesStrings.deleteConfirm, role: .destructive, action: onDelete) }
            // The thumbnail is read again after a clear (or not at all), and when the state changes.
            .task(id: "\(message.messageID)|\(a.state.rawValue)|\(generation)") { await load() }
        }
    }

    private func picture(_ a: AttachmentInfo, _ statusText: String?) -> some View {
        let head = message.outgoing ? MessagesStrings.photoCdOut : MessagesStrings.photoCdIn(name)
        return Button { actions.onOpen(message.messageID) } label: {
            ZStack {
                colors.surfaceContainerHighest.color
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    VettIDSymbol.image.image.font(.system(size: 28)).foregroundStyle(colors.onSurfaceVariant)
                }
            }
            .frame(width: Self.width, height: Self.width / Self.ratio(a))
            .clipShape(RoundedRectangle(cornerRadius: Spacing.m))
        }
        .buttonStyle(.plain)
        .disabled(!a.viewable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photoLabel(head, message.text, statusText))
        .accessibilityAddTraits(a.viewable ? .isButton : [])
        .accessibilityIdentifier("photo_\(message.messageID)")
        .accessibilityValue(thumb == nil ? "" : "shown")
    }

    private func load() async {
        thumb = nil // after a clear the old thumbnail goes first
        guard let bytes = await actions.thumbnail(message.messageID) else { return }
        thumb = await PhotoImages.thumbnail(bytes)
    }
}
#endif
