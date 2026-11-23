import DisplayCore
import SwiftUI

// View-local state is declared with the `State` type instead of the `@State` attribute.
// In the macOS 27 SDK the attribute is a macro, and its plugin ships with Xcode only, so
// the attribute does not compile with the Command Line Tools. The type behaves the same.

/// The panel under the menu bar item: one card per display, then app-wide controls.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    let quit: () -> Void
    var expandDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isSafeMode {
                Label("Safe mode. Nothing is restored or reapplied automatically.", systemImage: "shield.lefthalf.filled")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.cards.isEmpty {
                Text("No display is connected.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.cards) { card in
                DisplayCard(card: card, model: model, expandDetails: expandDetails)
            }
            if !model.remembered.isEmpty {
                RememberedSection(model: model)
            }
            ForEach(model.advice) { advice in
                AdviceRow(advice: advice, model: model)
            }
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Footer(model: model, quit: quit)
        }
        .padding(14)
        .frame(width: 348)
    }
}

// MARK: Card

struct DisplayCard: View {
    let card: PanelModel.Card
    @ObservedObject var model: PanelModel
    private let showsDetails: State<Bool>

    init(card: PanelModel.Card, model: PanelModel, expandDetails: Bool = false) {
        self.card = card
        self.model = model
        showsDetails = State(initialValue: expandDetails)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.name).font(.headline)
                    Text(card.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if card.isChecking {
                    ProgressView().controlSize(.small).help("Checking what this display supports")
                }
            }

            if let pending = card.pending {
                ConfirmationBanner(pending: pending, keep: { model.keep(tag: card.tag) }, revert: { model.revert(tag: card.tag) })
            }

            ValueRow(
                title: "Brightness", symbol: "sun.max", state: card.brightness,
                change: { value, final in model.setBrightness(value, tag: card.tag, final: final) }
            )

            if card.strip.count > 1 {
                SizeStrip(card: card) { model.choose($0, tag: card.tag) }
            } else if let mode = card.currentMode {
                LabeledContent("Resolution", value: mode.sizeLabel).font(.callout)
            }

            if card.volume.isAvailable {
                HStack(spacing: 8) {
                    ValueRow(
                        title: "Volume", symbol: card.isMuted ? "speaker.slash" : "speaker.wave.2", state: card.volume,
                        change: { value, final in model.setVolume(value, tag: card.tag, final: final) }
                    )
                    Button {
                        model.toggleMute(tag: card.tag)
                    } label: {
                        Image(systemName: card.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(card.isMuted ? "Unmute" : "Mute")
                    .accessibilityLabel(card.isMuted ? "Unmute \(card.name)" : "Mute \(card.name)")
                }
            }

            if card.inputReason == nil, !card.inputs.isEmpty {
                InputMenu(card: card, model: model)
            }

            DisclosureGroup("Details", isExpanded: showsDetails.projectedValue) {
                DetailView(card: card, model: model)
                    .padding(.top, 6)
            }
            .font(.callout)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.name)
    }
}

/// A labelled slider for a normalized value, or the reason the control cannot be used.
struct ValueRow: View {
    let title: String
    let symbol: String
    let state: PanelModel.ControlState
    let change: (_ value: Double, _ final: Bool) -> Void
    private let dragged = State<Double?>(initialValue: nil)

    private var shownValue: Double { dragged.wrappedValue ?? state.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(
                    value: Binding(
                        get: { shownValue },
                        set: { value in
                            dragged.wrappedValue = value
                            change(value, false)
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        guard !editing, let value = dragged.wrappedValue else { return }
                        change(value, true)
                        dragged.wrappedValue = nil
                    }
                )
                .disabled(!state.isAvailable)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((shownValue * 100).rounded())) percent")
                Text("\(Int((shownValue * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .opacity(state.isAvailable ? 1 : 0)
            }
            if let reason = state.reason {
                Text("\(title) is unavailable. \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The strip from "larger text" to "more space". The resolution is secondary detail,
/// and the change is applied when the drag ends.
struct SizeStrip: View {
    let card: PanelModel.Card
    let choose: (ModeDescriptor) -> Void
    private let dragged = State<Double?>(initialValue: nil)

    private var currentIndex: Double {
        Double(card.strip.firstIndex(where: \.isCurrent) ?? 0)
    }

    private var shown: SizeStripEntry {
        let index = Int((dragged.wrappedValue ?? currentIndex).rounded())
        return card.strip[min(max(index, 0), card.strip.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "textformat.size")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(
                    value: Binding(get: { dragged.wrappedValue ?? currentIndex }, set: { dragged.wrappedValue = $0 }),
                    in: 0...Double(card.strip.count - 1),
                    step: 1,
                    onEditingChanged: { editing in
                        guard !editing, let value = dragged.wrappedValue else { return }
                        let entry = card.strip[min(max(Int(value.rounded()), 0), card.strip.count - 1)]
                        if !entry.isCurrent { choose(entry.mode) }
                        dragged.wrappedValue = nil
                    }
                )
                .accessibilityLabel("Text size")
                .accessibilityValue("\(shown.mode.logicalWidth) by \(shown.mode.logicalHeight)")
            }
            HStack {
                Text("Larger text")
                Spacer()
                Text(shown.mode.sizeLabel + (shown.isDefault ? " · Default" : "") + (shown.isNativeUnscaled ? " · Native" : ""))
                    .monospacedDigit()
                Spacer()
                Text("More space")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 26)
        }
    }
}

struct ConfirmationBanner: View {
    let pending: PendingConfirmation
    let keep: () -> Void
    let revert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keep this display setting?")
                .font(.callout.weight(.medium))
            Text("It goes back on its own if you do not answer.")
                .font(.caption)
                .foregroundStyle(.secondary)
            CountdownBar(deadline: pending.deadline, seconds: pending.seconds)
            HStack {
                Button("Revert", action: revert)
                Button("Keep", action: keep)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A bar that empties until the deadline. One animation drives it, so nothing ticks.
struct CountdownBar: View {
    let deadline: Date
    let seconds: Double
    private let fraction = State(initialValue: 1.0)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint).frame(width: geometry.size.width * fraction.wrappedValue)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
        .onAppear {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            fraction.wrappedValue = seconds > 0 ? min(1, remaining / seconds) : 0
            withAnimation(.linear(duration: remaining)) { fraction.wrappedValue = 0 }
        }
    }
}

struct InputMenu: View {
    let card: PanelModel.Card
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cable.connector")
                .frame(width: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Menu(card.inputs.first { $0.id == card.currentInput }?.label ?? "Input") {
                ForEach(card.inputs) { entry in
                    Button(entry.label) { model.chooseInput(entry, card: card) }
                }
            }
            .accessibilityLabel("Input of \(card.name)")
        }
    }
}

// MARK: Details

/// Everything one level down. A control that cannot be used stays here with its reason.
struct DetailView: View {
    let card: PanelModel.Card
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.refreshRates.count > 1, let current = card.currentMode {
                Picker("Refresh rate", selection: Binding(
                    get: { card.refreshRates.first { ModeDescriptor.sameRate($0.refreshRate, current.refreshRate) } ?? current },
                    set: { model.choose($0, tag: card.tag) }
                )) {
                    ForEach(card.refreshRates, id: \.self) { mode in
                        Text(mode.rateLabel).tag(mode)
                    }
                }
            } else if let current = card.currentMode {
                LabeledContent("Refresh rate", value: current.rateLabel)
            }

            if let reason = card.rotationReason {
                Unavailable(title: "Rotation", reason: reason)
            } else if let rotation = card.rotation {
                Picker("Rotation", selection: Binding(get: { rotation }, set: { model.chooseRotation($0, tag: card.tag) })) {
                    ForEach([0, 90, 180, 270], id: \.self) { degrees in
                        Text("\(degrees)°").tag(degrees)
                    }
                }
            }

            if card.contrast.isAvailable {
                ValueRow(title: "Contrast", symbol: "circle.lefthalf.filled", state: card.contrast) { value, final in
                    model.setContrast(value, tag: card.tag, final: final)
                }
            } else if let reason = card.contrast.reason {
                Unavailable(title: "Contrast", reason: reason)
            }
            if !card.volume.isAvailable, let reason = card.volume.reason {
                Unavailable(title: "Volume", reason: reason)
            }
            if let reason = card.inputReason {
                Unavailable(title: "Input", reason: reason)
            }

            if let method = card.brightness.method {
                LabeledContent("Brightness through", value: method)
            }
            Text(card.softwareNote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(card.notes, id: \.self) { note in
                Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Brightness and volume keys control this display", isOn: Binding(
                get: { card.keyboardControl },
                set: { model.setKeyboardControl($0, tag: card.tag) }
            ))
            if card.offersRestoreAfterWake {
                Toggle("Put my values back after sleep", isOn: Binding(
                    get: { card.restoreAfterWake },
                    set: { model.setRestoreAfterWake($0, tag: card.tag) }
                ))
                .help("For a monitor that forgets its brightness, contrast or volume while it sleeps. Off: after wake, Display 16X reads the monitor and shows what it has.")
            }

            HStack {
                Text(card.identity).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Check Again") { model.checkAgain(tag: card.tag) }
                    .help("Ask the display again what it supports")
            }
        }
        .font(.caption)
        .controlSize(.small)
    }
}

struct Unavailable: View {
    let title: String
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(title) is unavailable")
            Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Lower sections

struct RememberedSection: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        DisclosureGroup("Not connected (\(model.remembered.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.remembered) { display in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(display.name)
                            Text("Last seen \(display.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") { model.forget(tag: display.tag) }
                            .help("Delete this display's saved settings")
                    }
                }
            }
            .font(.caption)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .font(.callout)
    }
}

struct AdviceRow: View {
    let advice: PermissionAdvice
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(advice.message, systemImage: "hand.raised")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            switch advice.topic {
            case .accessibility:
                Button("Open Accessibility Settings") { model.requestAccessibility() }
            case .loginItem:
                Button("Open Login Items") { model.openLoginItems() }
            }
        }
        .controlSize(.small)
    }
}

struct Footer: View {
    @ObservedObject var model: PanelModel
    let quit: () -> Void

    var body: some View {
        HStack {
            Menu {
                Toggle("Launch at login", isOn: Binding(get: { model.loginItem == .enabled || model.loginItem == .requiresApproval }, set: { model.setLaunchAtLogin($0) }))
                    .disabled(model.loginItem == .unavailable)
                Divider()
                Toggle("Brightness keys", isOn: Binding(get: { model.brightnessKeys }, set: { model.setBrightnessKeys($0) }))
                Toggle("Volume keys", isOn: Binding(get: { model.volumeKeys }, set: { model.setVolumeKeys($0) }))
                Picker("Keys control", selection: Binding(get: { model.keyTarget }, set: { model.setKeyTarget($0) })) {
                    Text("The display under the pointer").tag(KeyTargetPolicy.underPointer)
                    Text("The display with the active window").tag(KeyTargetPolicy.focused)
                    Text("All displays").tag(KeyTargetPolicy.all)
                }
                Divider()
                Toggle("Software dimming below the hardware range", isOn: Binding(get: { model.softwareDimming }, set: { model.setSoftwareDimming($0) }))
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Text("Display 16X \(AppPaths.version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit", action: quit)
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}
