import DisplayCore
import SwiftUI

/// The settings window: what applies to the whole app, in one place.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case scenes = "Scenes"
        case shortcuts = "Shortcuts"
        case scripting = "Scripting"
        case about = "About"

        var id: String { rawValue }
    }

    @ObservedObject var model: PanelModel
    @ObservedObject var layoutModel: LayoutPanelModel
    let openLink: (URL) -> Void
    private let tab: State<Tab>

    init(model: PanelModel, layoutModel: LayoutPanelModel, start: Tab = .general, openLink: @escaping (URL) -> Void) {
        self.model = model
        self.layoutModel = layoutModel
        self.openLink = openLink
        tab = State(initialValue: start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.xl) {
            Picker("Section", selection: tab.projectedValue) {
                ForEach(Tab.allCases) { (tab: Tab) in
                    Text(verbatim: tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            SettingsNotices(layoutModel: layoutModel, model: model)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Skin.space.l) { page }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Skin.space.window)
        .frame(width: Skin.size.settingsWidth, height: Skin.size.settingsHeight, alignment: .top)
        .background(Skin.color.canvas)
        .tint(Skin.color.accent)
    }

    @ViewBuilder private var page: some View {
        switch tab.wrappedValue {
        case .general: GeneralSettings(model: model)
        case .scenes: SceneSettings(layoutModel: layoutModel)
        case .shortcuts: ShortcutSettings(layoutModel: layoutModel)
        case .scripting: ScriptingSettings(layoutModel: layoutModel)
        case .about: AboutPane(openLink: openLink)
        }
    }
}

/// The recorder waiting for keys, and the last thing that was done or went wrong.
struct SettingsNotices: View {
    @ObservedObject var layoutModel: LayoutPanelModel
    @ObservedObject var model: PanelModel

    var body: some View {
        if let target = layoutModel.recordingFor {
            Banner(kind: .note, symbol: Skin.symbol.record, title: "Press the keys for \(target)", message: "Use at least one of Control, Option or Command. Escape cancels.") {
                Button("Cancel") { layoutModel.stopRecording() }.buttonStyle(QuietStyle())
            }
        }
        if let message = model.message {
            Banner(kind: .danger, symbol: Skin.symbol.danger, title: PanelText.sentence(message))
        }
        if let message = layoutModel.message {
            Banner(kind: layoutModel.messageIsFailure ? .danger : .note, symbol: layoutModel.messageIsFailure ? Skin.symbol.danger : Skin.symbol.confirmed, title: PanelText.sentence(message))
        }
    }
}

// MARK: General

struct GeneralSettings: View {
    @ObservedObject var model: PanelModel

    private var login: Binding<Bool> {
        Binding(get: { model.loginItem == .enabled || model.loginItem == .requiresApproval }, set: { model.setLaunchAtLogin($0) })
    }

    private var loginHelp: String? {
        switch model.loginItem {
        case .unavailable: "Not available for this copy of the app."
        case .requiresApproval: "Waiting for your approval under Login Items in System Settings."
        case .enabled, .disabled: nil
        }
    }

    private var brightnessKeys: Binding<Bool> {
        Binding(get: { model.brightnessKeys }, set: { model.setBrightnessKeys($0) })
    }

    private var volumeKeys: Binding<Bool> {
        Binding(get: { model.volumeKeys }, set: { model.setVolumeKeys($0) })
    }

    private var dimming: Binding<Bool> {
        Binding(get: { model.softwareDimming }, set: { model.setSoftwareDimming($0) })
    }

    private func name(_ target: KeyTargetPolicy) -> String {
        switch target {
        case .underPointer: "The display under the pointer"
        case .focused: "The display with the active window"
        case .all: "All displays"
        }
    }

    var body: some View {
        SkinBlock {
            SwitchRow(title: "Open Display 16X when you log in", help: loginHelp, isOn: login, isEnabled: model.loginItem != .unavailable)
        }
        SkinHeading(text: "Brightness and volume keys")
        SkinBlock {
            SwitchRow(title: "Brightness keys change a display's brightness", isOn: brightnessKeys)
            SkinRule()
            SwitchRow(title: "Volume keys change a monitor's volume", help: "Only while sound plays through that monitor.", isOn: volumeKeys)
            SkinRule()
            LineRow(title: "The keys reach") {
                PopupMenu(title: "The keys reach", shown: name(model.keyTarget)) {
                    Button(name(.underPointer)) { model.setKeyTarget(.underPointer) }
                    Button(name(.focused)) { model.setKeyTarget(.focused) }
                    Button(name(.all)) { model.setKeyTarget(.all) }
                }
            }
        }
        SkinHeading(text: "Software dimming")
        SkinBlock {
            SwitchRow(
                title: "Dim below the monitor's own range",
                help: "The picture gets darker once the monitor's own brightness is at its lowest. These values are sent and cannot be read back.",
                isOn: dimming
            )
            CostLine(text: "Costs nothing while it is on. macOS does the dimming.")
        }
    }
}

/// What a feature costs the Mac while it is on, next to its switch.
struct CostLine: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(Skin.type.caption).foregroundStyle(Skin.color.textTertiary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Scenes

struct SceneSettings: View {
    @ObservedObject var layoutModel: LayoutPanelModel

    private func keys(for name: String) -> String {
        layoutModel.shortcuts.first { $0.presetName == name }?.combo.description ?? "No shortcut"
    }

    var body: some View {
        Text("A scene is a saved setup: the sizes, rotation and arrangement of the connected displays. Apply one from the panel or with its shortcut.")
            .font(Skin.type.caption)
            .foregroundStyle(Skin.color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if !layoutModel.presets.isEmpty {
            SkinBlock {
                ForEach(layoutModel.presets, id: \.self) { (name: String) in
                    if name != layoutModel.presets.first { SkinRule() }
                    HStack(spacing: Skin.space.m) {
                        Text(verbatim: name).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text)
                        Text(verbatim: keys(for: name)).font(Skin.type.mono).foregroundStyle(Skin.color.textSecondary)
                        Spacer(minLength: Skin.space.xs)
                        Button("Apply") { layoutModel.applyPreset(name) }.buttonStyle(QuietStyle())
                        Button("Set Shortcut…") { layoutModel.recordPreset(name) }.buttonStyle(QuietStyle())
                        Button("Delete") { layoutModel.deletePreset(name) }.buttonStyle(QuietStyle())
                    }
                }
            }
        }
        Button("Save This Setup as a Scene…") { layoutModel.savePresetPrompt() }.buttonStyle(ProminentStyle())
    }
}

// MARK: Shortcuts

struct ShortcutSettings: View {
    @ObservedObject var layoutModel: LayoutPanelModel

    var body: some View {
        Text("Shortcuts work everywhere on the Mac. Add one from a scene, or from a display's page in the panel.")
            .font(Skin.type.caption)
            .foregroundStyle(Skin.color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if layoutModel.shortcuts.isEmpty {
            SkinBlock {
                Text("No shortcuts yet.").font(Skin.type.body).foregroundStyle(Skin.color.textSecondary)
            }
        } else {
            SkinBlock {
                ForEach(layoutModel.shortcuts) { (shortcut: LayoutPanelModel.Shortcut) in
                    if shortcut.id != layoutModel.shortcuts.first?.id { SkinRule() }
                    HStack(spacing: Skin.space.m) {
                        Text(verbatim: shortcut.combo.description).font(Skin.type.value).foregroundStyle(Skin.color.text)
                        VStack(alignment: .leading, spacing: Skin.space.hair) {
                            Text(verbatim: shortcut.title).font(Skin.type.body).foregroundStyle(Skin.color.text).lineLimit(1)
                            if shortcut.isTaken {
                                Text("Another app holds these keys, so they do not arrive here.").font(Skin.type.caption).foregroundStyle(Skin.color.attention)
                            }
                        }
                        Spacer(minLength: Skin.space.xs)
                        Button("Remove") { layoutModel.removeShortcut(shortcut.combo) }.buttonStyle(QuietStyle())
                    }
                }
            }
        }
    }
}

// MARK: Scripting

struct ScriptingSettings: View {
    @ObservedObject var layoutModel: LayoutPanelModel

    private var commandLine: Binding<Bool> {
        Binding(get: { layoutModel.commandLine }, set: { layoutModel.setCommandLine($0) })
    }

    private var links: Binding<Bool> {
        Binding(get: { layoutModel.links }, set: { layoutModel.setLinks($0) })
    }

    var body: some View {
        SkinBlock {
            SwitchRow(title: "The display16x command may control this app", help: "Off: the command can still ask for the status.", isOn: commandLine)
            SkinRule()
            SwitchRow(title: "Links may control this app", help: "display16x:// links, from Shortcuts and other apps. A link has to carry the token below.", isOn: links)
            if let token = layoutModel.linkToken {
                LineRow(title: "Token") {
                    Text(verbatim: token).font(Skin.type.mono).foregroundStyle(Skin.color.text).textSelection(.enabled).lineLimit(1)
                }
            }
        }
        SkinHeading(text: "Your settings")
        SkinBlock {
            HStack(spacing: Skin.space.m) {
                Button("Export…") { layoutModel.exportSettings() }.buttonStyle(QuietStyle())
                Button("Import…") { layoutModel.importSettings() }.buttonStyle(QuietStyle())
                Spacer()
                Button("Reset…") { layoutModel.resetSettings() }.buttonStyle(QuietStyle())
            }
        }
    }
}

// MARK: About

struct AboutPane: View {
    let openLink: (URL) -> Void

    var body: some View {
        VStack(spacing: Skin.space.l) {
            AppMark()
            Wordmark(font: Skin.type.aboutName)
            Text(verbatim: "Version \(AppPaths.version)").font(Skin.type.value).foregroundStyle(Skin.color.textSecondary)
            Text("The display controls macOS leaves out. Free and open source, written from scratch by 16X Brains.")
                .font(Skin.type.body)
                .foregroundStyle(Skin.color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Skin.space.m) {
                Button { AboutLinks.project.map(openLink) } label: { Label("Project Page", systemImage: Skin.symbol.link) }.buttonStyle(QuietStyle())
                Button { AboutLinks.company.map(openLink) } label: { Label("16X Brains", systemImage: Skin.symbol.link) }.buttonStyle(QuietStyle())
            }
            Text("MIT License").font(Skin.type.caption).foregroundStyle(Skin.color.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Skin.space.window)
    }
}

enum AboutLinks {
    static let project = URL(string: "https://github.com/engrmnaveed/macdisplay-16x")
    static let company = URL(string: "https://16xbrains.com/")
}

/// The app's mark until the icon is chosen: a display with its menu bar, in the accent color.
struct AppMark: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Skin.radius.card, style: .continuous)
        return ScreenGlyph(aspect: 16.0 / 10.0, isMain: true, tint: Skin.color.hudAccent)
            .frame(width: Skin.size.aboutMark, height: Skin.size.aboutMark)
            .background(Skin.color.hud, in: shape)
            .accessibilityHidden(true)
    }
}
