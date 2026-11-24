import DisplayCore
import SwiftUI

/// "HDR and color" on a display's page: HDR with what it costs, the color profile with its
/// HDR twin and fallback, reference presets where the display has them, and what the link
/// carries, which can be read and not chosen.
struct ColorSection: View {
    let tag: DisplayTag
    @ObservedObject var color: ColorPanelModel

    var body: some View {
        if let state = color.display(for: tag) {
            SkinHeading(text: "HDR and color")
            if let message = color.message {
                Banner(kind: color.messageIsFailure ? .danger : .note, symbol: color.messageIsFailure ? Skin.symbol.danger : Skin.symbol.confirmed, title: PanelText.sentence(message))
            }
            SkinBlock {
                HDRRows(state: state, color: color)
                SkinRule()
                ProfileRows(state: state, color: color)
                if !state.presets.isEmpty {
                    SkinRule()
                    PresetRow(state: state, color: color)
                }
                SkinRule()
                LinkRows(state: state)
            }
        }
    }
}

struct HDRRows: View {
    let state: ColorPanelModel.DisplayColor
    @ObservedObject var color: ColorPanelModel

    private var hdr: Binding<Bool> {
        Binding(get: { state.hdrOn }, set: { color.setHDR($0, tag: state.tag) })
    }

    private var protect: Binding<Bool> {
        Binding(get: { state.protectHDR }, set: { color.setDisplaySwitch(.protectHDR, $0, tag: state.tag) })
    }

    private var hardware: Binding<Bool> {
        Binding(get: { state.hardwareInHDR }, set: { color.setDisplaySwitch(.hardwareInHDR, $0, tag: state.tag) })
    }

    private var help: String {
        if !color.hdrControls { return "Turn on HDR controls in Settings, under Advanced, to switch it here." }
        return state.headroom.map { "\($0). Asks Keep or Revert after the switch." } ?? "Asks Keep or Revert after the switch."
    }

    var body: some View {
        if state.hdrAlways {
            LineRow(title: "High dynamic range") { Text("Always on").font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text) }
            Text(verbatim: state.hdrReason ?? "The display shows HDR content at all times.")
                .font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).fixedSize(horizontal: false, vertical: true)
            if color.upscaling {
                SkinRule()
                AboveWhiteRow(state: state, color: color)
            }
        } else if let reason = state.hdrReason, !state.hdrOffered {
            WhyRow(title: "High dynamic range", reason: reason)
        } else {
            SwitchRow(title: "High dynamic range", help: help, isOn: hdr, isEnabled: color.hdrControls)
            if color.hdrControls {
                SkinRule()
                SwitchRow(title: "Put HDR back when something changes it", isOn: protect)
                SkinRule()
                SwitchRow(title: "Brightness changes the backlight in HDR", help: state.sdrLevel, isOn: hardware)
            }
            CostLine(text: "Costs nothing. The display goes dark for a moment when HDR switches, and ordinary windows look paler in HDR.")
            if color.upscaling {
                SkinRule()
                AboveWhiteRow(state: state, color: color)
            }
        }
    }
}

/// Brightness above SDR white, where the user turned it on. Says why when it cannot be used.
struct AboveWhiteRow: View {
    let state: ColorPanelModel.DisplayColor
    @ObservedObject var color: ColorPanelModel

    private var shown: String {
        state.upscaleLevel > 0 ? state.upscaleFactor : "SDR white"
    }

    var body: some View {
        if let reason = state.upscaleReason {
            WhyRow(title: "Brighter than SDR white", reason: reason)
        } else {
            LineRow(title: "Brighter than SDR white") {
                PopupMenu(title: "Brightness above SDR white for \(state.name)", shown: shown) {
                    Button("SDR White") { color.setUpscale(0, tag: state.tag) }
                    Button("A Quarter of the Way") { color.setUpscale(0.25, tag: state.tag) }
                    Button("Halfway") { color.setUpscale(0.5, tag: state.tag) }
                    Button("All the Way") { color.setUpscale(1, tag: state.tag) }
                }
            }
            CostLine(text: "Keeps the GPU busy while the display is above white. Back to white at sleep, at a lock and when Display 16X quits.")
        }
    }
}

struct ProfileRows: View {
    let state: ColorPanelModel.DisplayColor
    @ObservedObject var color: ColorPanelModel

    private var protect: Binding<Bool> {
        Binding(get: { state.protectProfile }, set: { color.setDisplaySwitch(.protectProfile, $0, tag: state.tag) })
    }

    var body: some View {
        if !state.profileReadable {
            WhyRow(title: "Color profile", reason: ColorUnavailable.profiles)
        } else if !color.profileControls {
            LineRow(title: "Color profile") { Text(verbatim: state.profileName).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text) }
            Text("Turn on Color profiles in Settings, under Advanced, to choose one here.")
                .font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).fixedSize(horizontal: false, vertical: true)
        } else {
            LineRow(title: "Color profile") {
                PopupMenu(title: "Color profile for \(state.name)", shown: state.profileName) {
                    ProfileChoices(state: state, color: color) { color.chooseProfile($0, tag: state.tag) }
                }
            }
            if state.hdrOffered {
                SkinRule()
                LineRow(title: "Profile in HDR") {
                    PopupMenu(title: "Color profile in HDR for \(state.name)", shown: state.hdrProfile ?? "The same") {
                        Button("The Same as Without HDR") { color.chooseHDRProfile("none", tag: state.tag) }
                        Divider()
                        ProfileChoices(state: state, color: color) { color.chooseHDRProfile($0, tag: state.tag) }
                    }
                }
            }
            SkinRule()
            LineRow(title: "If it goes missing") {
                PopupMenu(title: "Profile to use when the chosen one is missing, for \(state.name)", shown: state.fallback.first ?? "The monitor's own") {
                    Button("The Monitor's Own") { color.chooseFallback("none", tag: state.tag) }
                    Divider()
                    ForEach(color.installed, id: \.path) { (profile: ColorProfile) in
                        Button(profile.name) { color.chooseFallback(profile.path, tag: state.tag) }
                    }
                }
            }
            SkinRule()
            SwitchRow(title: "Put this profile back when something changes it", help: state.hdrOffered ? "The profile without HDR, or the one in HDR, by what the display shows." : nil, isOn: protect)
            if state.profileAssigned {
                CostLine(text: "Software dimming pauses on every display while a profile of your own is assigned.")
            }
        }
    }
}

/// The monitor's own profile, then every installed one by where it lives.
struct ProfileChoices: View {
    let state: ColorPanelModel.DisplayColor
    @ObservedObject var color: ColorPanelModel
    let choose: (String) -> Void

    var body: some View {
        Button("The Monitor's Own") { choose("factory") }
        Divider()
        ForEach(color.installed, id: \.path) { (profile: ColorProfile) in
            Button(profile.name) { choose(profile.path) }
        }
    }
}

struct PresetRow: View {
    let state: ColorPanelModel.DisplayColor
    @ObservedObject var color: ColorPanelModel

    private var active: String {
        state.presets.first(where: \.isActive)?.name ?? "Not known"
    }

    var body: some View {
        LineRow(title: "Reference preset") {
            PopupMenu(title: "Reference preset for \(state.name)", shown: active) {
                ForEach(state.presets, id: \.index) { (preset: ReferencePreset) in
                    Button(preset.name) { color.choosePreset(preset, tag: state.tag) }
                }
            }
            .disabled(!color.profileControls)
        }
    }
}

/// What the link carries, read from macOS. None of it can be chosen.
struct LinkRows: View {
    let state: ColorPanelModel.DisplayColor

    private var ditheringText: String {
        state.dithering.map { $0 ? "On" : "Off" } ?? "Not reported"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.s) {
            HStack(spacing: Skin.space.m) {
                Text("The link").font(Skin.type.captionStrong).foregroundStyle(Skin.color.textSecondary)
                Spacer(minLength: Skin.space.s)
                MarkTag(text: "Read only", help: "Read from macOS. macOS offers no documented way to choose these.")
            }
            if let first = state.linkModes.first {
                Text(verbatim: "\(state.linkModes.count) color modes offered. macOS ranks first \(first).")
                    .font(Skin.type.body).foregroundStyle(Skin.color.text).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("macOS does not say how the link carries the picture.").font(Skin.type.body).foregroundStyle(Skin.color.textSecondary)
            }
            LineRow(title: "Dithering") { Text(verbatim: ditheringText).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text) }
            if !state.connectionOnlyRates.isEmpty {
                Text(verbatim: "The link also offers " + state.connectionOnlyRates.joined(separator: ", ") + ", which macOS leaves out of the list.")
                    .font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        var parts = ["The link, read only"]
        if let first = state.linkModes.first { parts.append("\(state.linkModes.count) color modes offered. macOS ranks first \(first)") }
        parts.append("Dithering \(ditheringText.lowercased())")
        if !state.connectionOnlyRates.isEmpty { parts.append("The link also offers " + state.connectionOnlyRates.joined(separator: ", ")) }
        return parts.joined(separator: ". ") + "."
    }
}
