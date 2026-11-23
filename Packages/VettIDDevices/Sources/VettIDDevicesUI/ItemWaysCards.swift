#if os(iOS)
import SwiftUI
import VettIDData
import VettIDDevices
import VettIDUI

private typealias Txt = ItemWaysStrings

/// The four switches and, under the ones that are on, their settings.
struct WaysMainPage: View {
    let state: ItemWaysState
    let actions: ItemWaysActions

    var body: some View {
        if let read = state.read {
            let d = state.draft
            let ro = state.readOnly
            // A read-only page shows the ways as read, and only Turn off on them; one whose turn-off could never be sent (no strict
            // reading, or another agent's item) offers none.
            let on = { (w: ItemWay) in d.map { $0.ways.contains(w) } ?? read.rawWays.contains { sameWay($0, w) } }
            let may = { (w: ItemWay) in !state.saving && (!ro || state.canTurnOff) && (!ro || on(w)) }
            DetailCard {
                WaySwitch(label: Txt.waysUse, checked: true, enabled: false, id: "ways_use") { _ in }
                Note(Txt.waysUseNote)
                WaySwitch(label: Txt.waysRun, checked: on(.run), enabled: may(.run), id: "ways_run", onChange: actions.onRun)
                WaySwitch(label: Txt.waysProxy, checked: on(.proxy), enabled: may(.proxy), id: "ways_proxy", onChange: actions.onProxy)
                WaySwitch(label: Txt.waysReveal, checked: on(.reveal), enabled: may(.reveal), id: "ways_reveal", onChange: actions.onReveal)
                Note(Txt.waysRevealNote)
            }
            .accessibilityIdentifier("ways_card")
            if let d {
                if d.run != nil { RunCard(state: state, draft: d, actions: actions) }
                if d.proxy != nil { ProxyCard(state: state, draft: d, actions: actions) }
            }
        }
    }

    private func sameWay(_ wire: String, _ w: ItemWay) -> Bool { wire.utf8.elementsEqual(w.wire.utf8) }
}

struct RunCard: View {
    let state: ItemWaysState
    let draft: ItemWays
    let actions: ItemWaysActions

    var body: some View {
        if let run = draft.run {
            DetailCard {
                CardHeading(Txt.waysProgramsTitle)
                if run.programs.isEmpty { Note(Txt.waysProgramsNone).accessibilityIdentifier("ways_programs_none") }
                ForEach(Array(run.programs.enumerated()), id: \.offset) { i, p in
                    ProgramRow(state: state, program: p, index: i, each: run.each, actions: actions)
                }
                if run.programs.count < ItemWaysRules.maxPrograms {
                    Text(Txt.waysAddProgram).vettIDFont(.titleSmall).padding(.top, Spacing.s)
                    PlainField(
                        label: Txt.waysProgramField, text: state.programInput, supporting: Txt.waysProgramHint,
                        error: state.programProblem.map(programProblemText), id: "ways_program_input", onChange: actions.onProgramInput,
                        onDone: actions.onAddProgram
                    )
                    SecondaryButton(Txt.waysAdd, action: actions.onAddProgram)
                        .disabled(state.programInput.isEmpty)
                        .accessibilityIdentifier("ways_program_add")
                } else {
                    Note(Txt.waysProgramTooMany)
                }
                WaySwitch(
                    label: Txt.waysEach, checked: run.each, enabled: !state.saving && !run.programs.isEmpty, id: "ways_each",
                    onChange: actions.onEach
                )
                .padding(.top, Spacing.s)
                if run.programs.isEmpty { Note(Txt.waysEachNeedsProgram).accessibilityIdentifier("ways_each_needs_program") }
                if !run.each { Note(Txt.waysEachOffHelp).accessibilityIdentifier("ways_each_off_help") }
            }
            .accessibilityIdentifier("ways_run_card")
        }
    }
}

/// A program's row: the program as AA8 shows strings, its variables, its fingerprint, the advice; tap: its page.
private struct ProgramRow: View {
    @Environment(\.vettIDColors) private var colors
    let state: ItemWaysState
    let program: RunProgram
    let index: Int
    let each: Bool
    let actions: ItemWaysActions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ShownStringBox(program.program)
            Text(program.env.isEmpty ? Txt.waysProgramNoVariables : program.env.joined(separator: ", "))
                .vettIDFont(.bodySmall)
                .foregroundStyle(colors.onSurfaceVariant)
            PinLine(state: state, program: program, onShow: actions.onShowPin)
            ProgramAdviceLines(program: program, each: each)
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.touchTarget, alignment: .leading)
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture { actions.onOpenProgram(index) }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("ways_program_\(index)")
    }
}

private struct ProgramAdviceLines: View {
    @Environment(\.vettIDColors) private var colors
    let program: RunProgram
    let each: Bool

    var body: some View {
        if ProgramAdvice.batchFile(program.program) { Note(Txt.waysBatchFile).accessibilityIdentifier("ways_batch_file") }
        if !each && ProgramAdvice.runsCommands(program.program) {
            Text(Txt.waysRunsCommands(ShownString.inline(ItemWaysRules.lastElement(program.program), empty: Txt.waysStringEmpty)))
                .vettIDFont(.bodySmall)
                .foregroundStyle(colors.error)
                .accessibilityIdentifier("ways_runs_commands")
        }
    }
}

/// The fingerprint line: recorded (16 digits, a tap shows all 64), forgotten when saved, or none yet.
private struct PinLine: View {
    let state: ItemWaysState
    let program: RunProgram
    let onShow: @MainActor (String?) -> Void

    var body: some View {
        if let sha = program.sha256, let path = program.path {
            Text(Txt.waysPinRecorded(Fingerprints.short(sha), ShownString.inline(path, empty: Txt.waysStringEmpty)))
                .vettIDFont(.bodySmall)
                .monospaced()
                .onTapGesture { onShow(sha) }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("ways_pin")
        } else if state.pinForgotten(program) {
            Note(Txt.waysPinForgotten).accessibilityIdentifier("ways_pin_forgotten")
        } else {
            Note(Txt.waysPinNone).accessibilityIdentifier("ways_pin_none")
        }
    }
}

/// A program's page: the program (changing it forgets the fingerprint), its variables, its fingerprint, Remove program.
struct ProgramPage: View {
    @Environment(\.vettIDColors) private var colors
    let state: ItemWaysState
    let program: RunProgram
    let index: Int
    let actions: ItemWaysActions

    var body: some View {
        let each = state.draft?.run?.each ?? true
        DetailCard {
            CardHeading(Txt.waysProgramField)
            ShownStringBox(program.program)
            PlainField(
                label: Txt.waysProgramField, text: state.editInput, supporting: Txt.waysChangeProgramNote,
                error: state.editProblem.map(programProblemText), id: "ways_program_edit", onChange: actions.onEditInput,
                onDone: actions.onApplyEdit
            )
            PinLine(state: state, program: program, onShow: actions.onShowPin)
            if program.sha256 != nil && program.path != nil {
                DeviceTextAction(label: Txt.waysPinForget, identifier: "ways_pin_forget") { actions.onForgetPin(index) }
            }
            ProgramAdviceLines(program: program, each: each)
        }
        .accessibilityIdentifier("ways_program_page")
        DetailCard {
            CardHeading(Txt.waysVariablesTitle)
            if program.env.isEmpty { Note(Txt.waysVariablesNone).accessibilityIdentifier("ways_variables_none") }
            ForEach(program.env, id: \.self) { name in
                HStack {
                    Text(name).vettIDFont(.bodyLarge).monospaced().frame(maxWidth: .infinity, alignment: .leading)
                    DeviceTextAction(label: Txt.waysRemove, identifier: "ways_variable_remove") { actions.onRemoveVariable(name) }
                }
                .accessibilityIdentifier("ways_variable_\(name)")
            }
            Text(Txt.waysAddVariable).vettIDFont(.titleSmall).padding(.top, Spacing.s)
            PlainField(
                label: Txt.waysVariableField, text: state.variableInput, supporting: Txt.waysVariableNote,
                error: state.variableProblem.map { $0 == .form ? Txt.waysVariableForm : Txt.waysVariableTooMany },
                id: "ways_variable_input", onChange: actions.onVariableInput, onDone: actions.onAddVariable
            )
            SecondaryButton(Txt.waysAdd, action: actions.onAddVariable)
                .disabled(state.variableInput.isEmpty)
                .accessibilityIdentifier("ways_variable_add")
        }
        .accessibilityIdentifier("ways_variables_card")
        PrimaryButton(Txt.waysRemoveProgram, destructive: true) { actions.onRemoveProgram(index) }
            .padding(.horizontal, Spacing.gutter)
            .accessibilityIdentifier("ways_program_remove")
    }
}

private func programProblemText(_ p: ProgramProblem) -> String {
    switch p {
    case .notPathOrName: Txt.waysProgramNotPath
    case .characters: Txt.waysProgramCharacters
    case .tooLong: Txt.waysProgramTooLong
    case .pathParts: Txt.waysProgramParts
    case .networkPath: Txt.waysProgramNetwork
    case .tilde: Txt.waysProgramTilde
    case .duplicate: Txt.waysProgramDuplicate
    case .tooMany: Txt.waysProgramTooMany
    }
}

private func hostProblemText(_ p: HostProblem) -> String {
    switch p {
    case .notAHost: Txt.waysHostNotHost
    case .ipAddress: Txt.waysHostIp
    case .local: Txt.waysHostLocal
    case .wildcard: Txt.waysHostWildcard
    case .duplicate: Txt.waysHostDuplicate
    case .tooMany: Txt.waysHostTooMany
    }
}

struct ProxyCard: View {
    let state: ItemWaysState
    let draft: ItemWays
    let actions: ItemWaysActions

    var body: some View {
        if let proxy = draft.proxy {
            DetailCard {
                CardHeading(Txt.waysHostsTitle)
                ForEach(proxy.hosts, id: \.self) { h in
                    HStack(alignment: .center) {
                        ShownStringBox(h)
                        DeviceTextAction(label: Txt.waysRemove, identifier: "ways_host_remove") { actions.onRemoveHost(h) }
                            .disabled(proxy.hosts.count <= 1)
                    }
                    .accessibilityIdentifier("ways_host_\(h)")
                }
                if proxy.hosts.count < ItemWaysRules.maxHosts {
                    Text(Txt.waysAddHost).vettIDFont(.titleSmall).padding(.top, Spacing.s)
                    PlainField(
                        label: Txt.waysHostField, text: state.hostInput, supporting: Txt.waysHostHint,
                        error: state.hostProblem.map(hostProblemText), id: "ways_host_input", focus: state.addingHost,
                        onChange: actions.onHostInput, onDone: actions.onAddHost
                    )
                    SecondaryButton(Txt.waysAdd, action: actions.onAddHost)
                        .disabled(state.hostInput.isEmpty)
                        .accessibilityIdentifier("ways_host_add")
                } else {
                    Note(Txt.waysHostTooMany)
                }
                PlainField(
                    label: Txt.waysHeaderField, text: proxy.header,
                    error: ItemWaysRules.headerValid(proxy.header) ? nil : Txt.waysHeaderBad, id: "ways_header",
                    onChange: actions.onHeader
                )
                PlainField(
                    label: Txt.waysPrefixField, text: proxy.prefix,
                    error: ItemWaysRules.prefixValid(proxy.prefix) ? nil : Txt.waysPrefixBad, id: "ways_prefix",
                    onChange: actions.onPrefix
                )
                Text(Txt.waysSentAs(proxy.header, markSpaces(proxy.prefix)))
                    .vettIDFont(.bodyMedium)
                    .monospaced()
                    .padding(.top, Spacing.s)
                    .accessibilityIdentifier("ways_sent_as")
                Note(Txt.waysSentNote)
            }
            .accessibilityIdentifier("ways_proxy_card")
        }
    }

    /// A space at the end of the prefix shown as a visible mark (AA7 "Before the key").
    private func markSpaces(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "␣") }
}

// MARK: Parts

struct WaySwitch: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let checked: Bool
    let enabled: Bool
    let id: String
    let onChange: @MainActor (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { checked }, set: { onChange($0) })) {
            Text(label).vettIDFont(.bodyLarge)
        }
        .tint(colors.primary.color)
        .disabled(!enabled)
        .frame(minHeight: Spacing.touchTarget)
        .accessibilityIdentifier(id)
    }
}

struct CardHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).vettIDFont(.titleSmall, weight: .semibold).padding(.bottom, Spacing.s).accessibilityAddTraits(.isHeader)
    }
}

struct Note: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
    }
}

/// A field of this page: what is typed is what is saved (no suggestions, autocorrection, smart punctuation, inline predictions,
/// capitals or AutoFill: IOS-PLAN §6.5), with its label, its help and its refusal under it.
struct PlainField: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let text: String
    var supporting: String?
    var error: String?
    let id: String
    var focus = false
    let onChange: @MainActor (String) -> Void
    var onDone: @MainActor () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label).vettIDFont(.labelMedium).foregroundStyle(colors.onSurfaceVariant)
            VisibleSecretField(
                label, text: Binding(get: { text }, set: { onChange($0) }), monospaced: true, keyboard: .default, isError: error != nil,
                focus: focus, onSubmit: onDone
            )
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityIdentifier(id)
            if let t = error ?? supporting {
                Text(t).vettIDFont(.bodySmall).foregroundStyle(error == nil ? colors.onSurfaceVariant : colors.error)
                    .announced(error ?? "", .polite)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}
#endif
