import DisplayCore
import SwiftUI

/// The Advanced tab of the settings window: three switches, each off until turned on and
/// with its cost next to it, the virtual screens, and everything written outside the app.
struct AdvancedSettingsPane: View {
    @ObservedObject var advanced: AdvancedPanelModel

    var body: some View {
        if let message = advanced.message {
            Banner(kind: advanced.messageIsFailure ? .danger : .note, symbol: advanced.messageIsFailure ? Skin.symbol.danger : Skin.symbol.confirmed, title: PanelText.sentence(message))
        }
        AdvancedSwitches(advanced: advanced)
        VirtualScreenList(advanced: advanced)
        WrittenFiles(advanced: advanced)
    }
}

struct AdvancedSwitches: View {
    @ObservedObject var advanced: AdvancedPanelModel

    private func binding(_ feature: FeatureID, _ value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { advanced.setSwitch(feature, $0) })
    }

    var body: some View {
        Text("Each of these is off until you turn it on.")
            .font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary)
        SkinBlock {
            SwitchRow(
                title: "Scaling through overrides", help: advanced.overridesReason == nil || advanced.overridesEnabled ? "More sizes for a model of display, from a file Display 16X writes with your administrator password and can remove again." : advanced.overridesReason,
                isOn: binding(.overridesEnabled, advanced.overridesEnabled)
            )
            CostLine(text: "Costs nothing once the file is written. macOS does the scaling.")
            SkinRule()
            SwitchRow(title: "Virtual screens", help: "Screens that exist only in the Mac, for headless and remote use.", isOn: binding(.virtualScreensEnabled, advanced.virtualEnabled))
            CostLine(text: "Nothing while none is connected. A connected one holds memory for its picture, and apps draw to it like any display.")
            SkinRule()
            SwitchRow(title: "Mirror-based HiDPI", help: "A display shows a HiDPI virtual screen's picture, for a panel macOS gives no HiDPI sizes of its own. Starts when a screen linked with mirroring connects.", isOn: binding(.mirrorHiDPIEnabled, advanced.mirrorEnabled), isEnabled: advanced.virtualEnabled)
            CostLine(text: "Keeps the GPU busy: the whole screen is copied at every refresh while a display shows it.")
        }
    }
}

struct VirtualScreenList: View {
    @ObservedObject var advanced: AdvancedPanelModel

    var body: some View {
        SkinHeading(text: "Virtual screens")
        SkinBlock {
            if advanced.screens.isEmpty {
                Text("No virtual screens yet.").font(Skin.type.body).foregroundStyle(Skin.color.textSecondary)
            }
            ForEach(advanced.screens) { (screen: AdvancedPanelModel.Screen) in
                if screen.id != advanced.screens.first?.id { SkinRule() }
                VirtualScreenRow(screen: screen, advanced: advanced)
            }
            Button("New Virtual Screen…") { advanced.newScreenPrompt() }
                .buttonStyle(QuietStyle())
                .disabled(!advanced.virtualEnabled)
        }
    }
}

struct VirtualScreenRow: View {
    let screen: AdvancedPanelModel.Screen
    @ObservedObject var advanced: AdvancedPanelModel

    private var connected: Binding<Bool> {
        Binding(get: { screen.isConnected }, set: { advanced.setConnected(screen, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.xs) {
            SwitchRow(title: screen.name, help: screen.summary, isOn: connected, isEnabled: advanced.virtualEnabled)
            if let link = screen.link {
                Text(verbatim: link).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary)
            }
            if screen.isPaused {
                Text("Stopped connecting by itself after three times in two minutes. Connect it by hand to start again.")
                    .font(Skin.type.caption).foregroundStyle(Skin.color.attention).fixedSize(horizontal: false, vertical: true)
            }
            Button("Discard…") { advanced.discard(screen) }.buttonStyle(TextLinkStyle())
        }
    }
}

/// Every file Display 16X wrote outside its folder, with the way to remove it.
struct WrittenFiles: View {
    @ObservedObject var advanced: AdvancedPanelModel

    var body: some View {
        SkinHeading(text: "Written outside the app")
        SkinBlock {
            if advanced.written.isEmpty && advanced.movedAside.isEmpty {
                Text("Nothing. Display 16X has written no file outside its own folder.").font(Skin.type.body).foregroundStyle(Skin.color.textSecondary)
            }
            ForEach(advanced.written) { (file: AdvancedPanelModel.Written) in
                if file.id != advanced.written.first?.id { SkinRule() }
                WrittenRow(file: file)
            }
            ForEach(advanced.movedAside, id: \.self) { (path: String) in
                Text(verbatim: "Moved aside by a full reset: \(path)").font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            WrittenActions(advanced: advanced)
        }
    }
}

struct WrittenRow: View {
    let file: AdvancedPanelModel.Written

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.xxs) {
            Text(verbatim: file.title).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text)
            Text(verbatim: file.path).font(Skin.type.mono).foregroundStyle(Skin.color.textSecondary).lineLimit(2).textSelection(.enabled)
            ForEach(file.facts, id: \.self) { (fact: String) in
                Text(verbatim: fact).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary)
            }
            if let note = file.note {
                Text(verbatim: note).font(Skin.type.caption).foregroundStyle(Skin.color.attention)
            }
        }
    }
}

struct WrittenActions: View {
    @ObservedObject var advanced: AdvancedPanelModel

    var body: some View {
        HStack(spacing: Skin.space.s) {
            if !advanced.written.isEmpty {
                Button("Remove All…") { advanced.previewRemoval(tag: nil) }.buttonStyle(QuietStyle())
            }
            if !advanced.movedAside.isEmpty {
                Button("Put Back…") { advanced.previewPutBack() }.buttonStyle(QuietStyle())
            }
            Spacer(minLength: Skin.space.xs)
            Button("Full Reset…") { advanced.previewFullReset(includingSystem: true) }.buttonStyle(QuietStyle())
        }
    }
}
