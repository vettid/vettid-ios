#if os(iOS)
import SwiftUI
import VettIDCalls
import VettIDUI

/// What the call screen can do (vettid-android `CallActions`).
public struct CallActions {
    public var onAnswer: @MainActor () -> Void
    public var onDecline: @MainActor () -> Void
    public var onHangUp: @MainActor () -> Void
    public var onMute: @MainActor () -> Void
    public var onSpeaker: @MainActor () -> Void
    public var onDismiss: @MainActor () -> Void

    public init(
        onAnswer: @escaping @MainActor () -> Void = {}, onDecline: @escaping @MainActor () -> Void = {},
        onHangUp: @escaping @MainActor () -> Void = {}, onMute: @escaping @MainActor () -> Void = {},
        onSpeaker: @escaping @MainActor () -> Void = {}, onDismiss: @escaping @MainActor () -> Void = {}
    ) {
        self.onAnswer = onAnswer
        self.onDecline = onDecline
        self.onHangUp = onHangUp
        self.onMute = onMute
        self.onSpeaker = onSpeaker
        self.onDismiss = onDismiss
    }
}

/// The call, full screen: who, what is happening, and what can be done about it. Mirrors vettid-android `CallScreen`. The other
/// member's name shows only here, in VettID's own screens (CallKit's screen says "VettID call").
public struct CallScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: CallUiState
    let actions: CallActions
    let now: @MainActor () -> Date

    public init(_ state: CallUiState, actions: CallActions, now: @escaping @MainActor () -> Date = { Date() }) {
        self.state = state
        self.actions = actions
        self.now = now
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: Spacing.xxxl)
            InitialTile(state.tileName, size: 96)
            Spacer().frame(height: Spacing.l)
            Text(state.shownName)
                .vettIDFont(.headlineMedium)
                .foregroundStyle(colors.onSurface.color)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("call_name")
            Spacer().frame(height: Spacing.s)
            switch state.call {
            case .live(let call): LiveCall(call: call, state: state, actions: actions, now: now)
            case .ended(let call): EndedCall(call: call, state: state, onDismiss: actions.onDismiss)
            case .idle: Spacer()
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.background.color.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call_screen")
    }
}

private struct LiveCall: View {
    @Environment(\.vettIDColors) private var colors
    let call: CallState.Live
    let state: CallUiState
    let actions: CallActions
    let now: @MainActor () -> Date

    var body: some View {
        let line = CallTexts.phase(call.phase, reconnecting: call.reconnecting, name: state.shownName)
        Group {
            if let line {
                // What is happening is read out when it changes (calling, ringing, connecting, reconnecting).
                Text(line)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("call_status")
            } else {
                // The ticking time is not announced (it would speak every second): read as "Call time ..." when reached.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let clock = CallElapsed.text(since: call.activeSince, now: now())
                    Text(clock)
                        .monospacedDigit()
                        .accessibilityLabel(CallStrings.durationSpoken(clock))
                        .accessibilityIdentifier("call_status")
                }
            }
        }
        .vettIDFont(.titleMedium)
        .foregroundStyle(colors.onSurfaceVariant.color)
        .multilineTextAlignment(.center)
        if call.phase == .active {
            Spacer().frame(height: Spacing.l)
            HStack(spacing: Spacing.s) {
                VettIDSymbol.lock.image.scaledIcon(size: 18, weight: .regular)
                    .foregroundStyle(colors.primary.color).accessibilityHidden(true)
                Text(CallStrings.encryption(state.shownName)).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("call_encryption")
        }
        Spacer()
        if call.phase == .incoming {
            HStack {
                Spacer()
                RoundAction(.callEnd, label: CallStrings.decline, id: "call_decline", destructive: true, action: actions.onDecline)
                Spacer()
                RoundAction(.call, label: CallStrings.answer, id: "call_answer", destructive: false, action: actions.onAnswer)
                Spacer()
            }
        } else {
            HStack {
                Spacer()
                ToggleAction(
                    .micOff, label: CallStrings.mute, onLabel: CallStrings.mutedOn, on: call.muted, id: "call_mute", enabled: true,
                    action: actions.onMute
                )
                Spacer()
                RoundAction(.callEnd, label: CallStrings.hangUp, id: "call_hang_up", destructive: true, action: actions.onHangUp)
                Spacer()
                ToggleAction(
                    .volumeUp, label: CallStrings.speaker, onLabel: CallStrings.speakerOn, on: state.speaker, id: "call_speaker",
                    enabled: state.canSpeaker, action: actions.onSpeaker
                )
                Spacer()
            }
        }
    }
}

private struct EndedCall: View {
    @Environment(\.vettIDColors) private var colors
    let call: CallState.Ended
    let state: CallUiState
    let onDismiss: @MainActor () -> Void

    var body: some View {
        Text(CallTexts.ended(call.reason, name: state.shownName, firstName: state.firstName))
            .vettIDFont(.titleMedium)
            .foregroundStyle(CallTexts.isError(call.reason) ? colors.error.color : colors.onSurfaceVariant.color)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("call_ended")
        Spacer()
        PrimaryButton(CallStrings.close, action: onDismiss).accessibilityIdentifier("call_close")
    }
}

/// The time since media first flowed.
enum CallElapsed {
    static func text(since: Date?, now: Date) -> String {
        CallTexts.clock(since.map { Int64(now.timeIntervalSince($0)) } ?? 0)
    }
}

private let actionSize: CGFloat = 64

private struct RoundAction: View {
    @Environment(\.vettIDColors) private var colors
    let symbol: VettIDSymbol
    let label: String
    let id: String
    let destructive: Bool
    let action: @MainActor () -> Void

    init(_ symbol: VettIDSymbol, label: String, id: String, destructive: Bool, action: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.label = label
        self.id = id
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Button(action: action) {
                symbol.image.scaledIcon(size: 26, weight: .regular)
                    .foregroundStyle(destructive ? colors.onError.color : colors.onPrimary.color)
                    .frame(width: actionSize, height: actionSize)
                    .background(Circle().fill(destructive ? colors.error.color : colors.primary.color))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
            Text(label).vettIDFont(.labelMedium).foregroundStyle(colors.onSurface.color)
        }
    }
}

private struct ToggleAction: View {
    @Environment(\.vettIDColors) private var colors
    let symbol: VettIDSymbol
    let label: String
    let onLabel: String
    let on: Bool
    let id: String
    let enabled: Bool
    let action: @MainActor () -> Void

    init(
        _ symbol: VettIDSymbol, label: String, onLabel: String, on: Bool, id: String, enabled: Bool,
        action: @escaping @MainActor () -> Void
    ) {
        self.symbol = symbol
        self.label = label
        self.onLabel = onLabel
        self.on = on
        self.id = id
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Button(action: action) {
                symbol.image.scaledIcon(size: 26, weight: .regular)
                    .foregroundStyle(on ? colors.onPrimary.color : colors.onSurface.color)
                    .frame(width: actionSize, height: actionSize)
                    .background(Circle().fill(on ? colors.primary.color : colors.surfaceContainerHigh.color))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.38)
            // Spoken as the on label when on (vettid-android: contentDescription = if (on) onLabel else label).
            .accessibilityLabel(on ? onLabel : label)
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier(id)
            Text(label).vettIDFont(.labelMedium).foregroundStyle(colors.onSurface.color)
        }
    }
}
#endif
