#if os(iOS)
import SwiftUI
import VettIDData
import VettIDSettings
import VettIDUI

/// Where the Credential screen's other rows lead: the rotation, the clone alarm's review and a new credential.
public struct CredentialRouteLinks {
    public var onRotate: @MainActor () -> Void = {}
    public var onReviewAlarm: @MainActor () -> Void = {}
    public var onNewCredential: @MainActor () -> Void = {}

    public init() {}
}

/// Credential → Rotate the credential key with its view model, also opened by the offer after a PIN or password change.
/// Mirrors vettid-android's `CredentialRotateRoute` destination.
public struct RotateRoute: View {
    private let repo: any CredentialRepository
    private let onBack: @MainActor () -> Void
    @State private var model: RotateViewModel?

    public init(repo: any CredentialRepository, onBack: @escaping @MainActor () -> Void) {
        self.repo = repo
        self.onBack = onBack
    }

    public var body: some View {
        RotateContent(state: model?.state ?? RotateState(), actions: actions)
            .onAppear { if model == nil { model = RotateViewModel(repo: repo) } }
    }

    private var actions: RotateActions {
        var a = RotateActions()
        let m = model
        a.onPassword = { m?.setPassword($0) }
        a.onSubmit = { m?.submit() }
        a.onForgetSecrets = { m?.forgetSecrets() }
        a.onBack = onBack
        return a
    }
}

/// The clone alarm with its view model, from the Credential screen's "Review" or the shell's banner. Mirrors
/// vettid-android's `CredentialAlarmRoute` destination.
public struct AlarmRoute: View {
    private let repo: any CredentialRepository
    private let onBack: @MainActor () -> Void
    @State private var model: AlarmViewModel?

    public init(repo: any CredentialRepository, onBack: @escaping @MainActor () -> Void) {
        self.repo = repo
        self.onBack = onBack
    }

    public var body: some View {
        AlarmContent(state: model?.state ?? AlarmState(alarm: repo.alarm, step: AlarmState.step(for: repo.alarm)), actions: actions)
            .onAppear { if model == nil { model = AlarmViewModel(repo: repo) } }
    }

    private var actions: AlarmActions {
        var a = AlarmActions()
        let m = model
        a.answer = { m?.answer(mine: $0) }
        a.cancelAnswer = { m?.cancelAnswer() }
        a.confirm = { m?.confirm() }
        a.setPassword = { m?.setPassword($0) }
        a.rotate = { m?.rotate() }
        a.forgetSecrets = { m?.forgetSecrets() }
        a.back = onBack
        return a
    }
}

/// Credential → New credential with its view model. Mirrors vettid-android's `CredentialNewRoute` destination.
public struct NewCredentialRoute: View {
    private let repo: any CredentialRepository
    private let onBack: @MainActor () -> Void
    @State private var model: NewCredentialViewModel?

    public init(repo: any CredentialRepository, onBack: @escaping @MainActor () -> Void) {
        self.repo = repo
        self.onBack = onBack
    }

    public var body: some View {
        NewCredentialContent(state: model?.state ?? NewCredentialState(), actions: actions)
            .onAppear { if model == nil { model = NewCredentialViewModel(repo: repo) } }
    }

    private var actions: NewCredentialActions {
        var a = NewCredentialActions()
        let m = model
        a.setCurrent = { m?.setCurrent($0) }
        a.setPassword = { m?.setPassword($0) }
        a.setConfirm = { m?.setConfirm($0) }
        a.setAcknowledged = { m?.setAcknowledged($0) }
        a.submit = { pin in
            if let pin { m?.setPin(pin) }
            m?.submit()
        }
        a.cancelConfirm = { m?.cancelConfirm() }
        a.confirm = { m?.confirm() }
        a.forgetSecrets = { m?.forgetSecrets() }
        a.back = onBack
        return a
    }
}
#endif
