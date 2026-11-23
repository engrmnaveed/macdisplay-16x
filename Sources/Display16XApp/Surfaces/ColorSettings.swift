import DisplayCore
import SwiftUI

/// The v0.4 part of the Advanced tab: three switches, each off until turned on and with its
/// cost next to it, and what Night Shift and True Tone are doing.
struct ColorSettingsPane: View {
    @ObservedObject var color: ColorPanelModel

    private func binding(_ feature: FeatureID, _ value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { color.setSwitch(feature, $0) })
    }

    var body: some View {
        SkinHeading(text: "HDR and color")
        if let message = color.message {
            Banner(kind: color.messageIsFailure ? .danger : .note, symbol: color.messageIsFailure ? Skin.symbol.danger : Skin.symbol.confirmed, title: PanelText.sentence(message))
        }
        SkinBlock {
            SwitchRow(title: "HDR controls", help: "Switch HDR from a display's page, put it back when something changes it, and keep brightness off the backlight in HDR if you ask.", isOn: binding(.hdrControls, color.hdrControls))
            CostLine(text: "Costs nothing while idle. macOS does the HDR.")
            SkinRule()
            SwitchRow(title: "Night Shift and True Tone off in HDR", help: color.togglesLine, isOn: binding(.nightShiftInHDR, color.nightShiftInHDR), isEnabled: color.hdrControls)
            CostLine(text: "Only what was on is turned off, and it comes back on when no display shows HDR, or when Display 16X quits.")
            SkinRule()
            SwitchRow(title: "Color profiles", help: "Choose a display's profile and reference preset from its page, with one to fall back to and one for HDR.", isOn: binding(.profileControls, color.profileControls))
            CostLine(text: "Costs nothing. Software dimming pauses on every display while a profile of your own is assigned.")
            SkinRule()
            SwitchRow(title: "Brightness above SDR white", help: "On a display with HDR switched on, go brighter than white from its page or with the brightness keys past 100%.", isOn: binding(.upscaling, color.upscaling))
            CostLine(text: "Keeps the GPU busy while a display is above white. Never kept across a restart.")
        }
    }
}

/// Keep or Revert for HDR, a color profile or a reference preset, on the display that changed.
struct ColorConfirmationView: View {
    let name: String
    /// "Keep HDR on?"
    let question: String
    /// What it goes back to: "HDR off".
    let fallback: String
    let deadline: Date
    let seconds: Double
    let keep: () -> Void
    let revert: () -> Void

    var body: some View {
        WindowBody(width: Skin.size.keepWindowWidth) {
            HStack(alignment: .center, spacing: Skin.space.xxl) {
                CountdownRing(deadline: deadline, seconds: seconds)
                VStack(alignment: .leading, spacing: Skin.space.xs) {
                    Text(verbatim: question).font(Skin.type.windowTitle).foregroundStyle(Skin.color.text).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "\(name) goes back to \(fallback) if you do not answer.")
                        .font(Skin.type.body)
                        .foregroundStyle(Skin.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    KeepButtons(keep: keep, revert: revert)
                }
            }
        }
    }
}
