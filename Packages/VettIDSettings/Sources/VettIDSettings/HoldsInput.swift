/// Whether a screen's state holds input or an operation a due daily check must not interrupt (VAULT-MESSAGING §3.6.5: "an
/// approval, a call, a credential operation"), so that it waits (at most the app's 5-minute limit) before covering the
/// screen. A started credential operation counts from the moment its screen opens until it is done or sent, typed or not
/// (name change, change PIN, change password, Delete vault, rotate, new credential, new phone secret, the alarm, a transfer
/// to a new phone); so does the credential window's dialog. VAULT-MESSAGING §3.6.5: the check does not
/// interrupt a call. iOS has no calls yet. Read here as: the call's own UI stays up while the shell is covered, so a call
/// does not hold input (the spec's wording on this is pending).
public extension ChangeNameState {
    /// From the moment the form is open until the request is sent.
    var holdsInput: Bool { step != .sent }
}

public extension DeleteVaultState {
    /// The deletion form is open (the vault's deletion ends it by changing the app's phase).
    var holdsInput: Bool { true }
}

public extension RotateState {
    var holdsInput: Bool { !done }
}

public extension NewCredentialState {
    var holdsInput: Bool { !done }
}

public extension ChangePinState {
    var holdsInput: Bool { !done }
}

public extension ChangePasswordState {
    var holdsInput: Bool { !done }
}

public extension AlarmState {
    /// From the question until it is resolved.
    var holdsInput: Bool { step != .resolved }
}

public extension TransferOutState {
    /// From the screen's opening until the transfer ends (expired, rejected or moved).
    var holdsInput: Bool { ![.expired, .rejected, .moved].contains(step) }
}

public extension NewPhoneSecretState {
    var holdsInput: Bool { !done }
}

public extension CredentialState {
    /// The window dialog open, or its password typed.
    var holdsInput: Bool { windowDialog || !windowPassword.isEmpty }
}
