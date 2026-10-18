import SwiftUI

/// The bytes of a PIN, zeroed when this box goes, whatever thread drops it. Capacity is reserved up front, so the
/// array never reallocates and leaves no copy of earlier digits behind.
private final class PinBytes: @unchecked Sendable {
    var bytes: [UInt8] = []

    init() { bytes.reserveCapacity(PinBuffer.maxDigits) }

    func zero() {
        for i in bytes.indices { bytes[i] = 0 }
        bytes.removeAll(keepingCapacity: true)
    }

    deinit { zero() }
}

/// The digits of a vault PIN while they are typed (IOS-PLAN §6.5, ID11): ASCII digits in a byte buffer that is zeroed
/// when it is cleared, taken or dropped, never a `String` that outlives the screen. ``take()`` hands the PIN over once,
/// as the request that carries it is built; the caller does not keep the string.
@MainActor
@Observable
public final class PinBuffer {
    public nonisolated static let maxDigits = 32

    @ObservationIgnored private let store = PinBytes()
    /// How many digits are typed (what the dots show).
    public private(set) var count = 0

    public init() {}

    public func append(_ d: Int) {
        guard (0...9).contains(d), store.bytes.count < Self.maxDigits else { return }
        store.bytes.append(UInt8(0x30 + d))
        count = store.bytes.count
    }

    public func deleteLast() {
        guard !store.bytes.isEmpty else { return }
        store.bytes[store.bytes.count - 1] = 0
        store.bytes.removeLast()
        count = store.bytes.count
    }

    /// Zeroes and empties the buffer.
    public func clear() {
        store.zero()
        count = 0
    }

    /// The PIN, once: the buffer is cleared.
    public func take() -> String {
        let s = String(bytes: store.bytes, encoding: .ascii) ?? ""
        clear()
        return s
    }
}

/// The in-app keypad for the vault PIN (IOS-PLAN §6.5, ID11): no keyboard at all, so no keyboard (Apple's or another)
/// ever sees the PIN, and nothing can autofill or offer to save it. Dots show how many digits are typed.
public struct PinKeypad: View {
    private let buffer: PinBuffer
    private let length: Int
    @Environment(\.vettIDColors) private var colors

    /// [length]: the dots shown (6 by default; the PIN may be longer, up to ``PinBuffer/maxDigits``).
    public init(buffer: PinBuffer, length: Int = 6) {
        self.buffer = buffer
        self.length = length
    }

    public var body: some View {
        VStack(spacing: Spacing.xl) {
            HStack(spacing: Spacing.m) {
                ForEach(0..<max(length, buffer.count), id: \.self) { i in
                    Circle()
                        .fill(i < buffer.count ? colors.onSurface.color : Color.clear)
                        .overlay(Circle().stroke(colors.outline))
                        .frame(width: 14, height: 14)
                }
            }
            .accessibilityElement()
            .accessibilityValue("\(buffer.count)")
            Grid(horizontalSpacing: Spacing.l, verticalSpacing: Spacing.m) {
                ForEach(0..<3) { row in
                    GridRow { ForEach(1...3, id: \.self) { col in key(row * 3 + col) } }
                }
                GridRow {
                    Color.clear.frame(width: 72, height: 72)
                    key(0)
                    Button { buffer.deleteLast() } label: {
                        Image(systemName: "delete.left").font(.title2).frame(width: 72, height: 72)
                    }
                    .foregroundStyle(colors.onSurface)
                    .accessibilityLabel(UIStrings.keypadDelete)
                    .accessibilityIdentifier("pin_delete")
                }
            }
        }
    }

    private func key(_ d: Int) -> some View {
        Button { buffer.append(d) } label: {
            Text(verbatim: String(d))
                .vettIDFont(.headlineMedium)
                .frame(width: 72, height: 72)
                .background(colors.surfaceContainerHigh, in: Circle())
        }
        .foregroundStyle(colors.onSurface)
        .accessibilityIdentifier("pin_\(d)")
    }
}
