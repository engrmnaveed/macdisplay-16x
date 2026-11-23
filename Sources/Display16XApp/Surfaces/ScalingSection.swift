import DisplayCore
import SwiftUI

/// "More sizes" on a display's page: what an override for the display's model adds, what
/// macOS made of it, and what waits to be written.
struct ScalingSection: View {
    let tag: DisplayTag
    @ObservedObject var advanced: AdvancedPanelModel

    var body: some View {
        if let scaling = advanced.scaling(for: tag) {
            SkinHeading(text: "More sizes")
            if !advanced.overridesEnabled && scaling.installed.isEmpty {
                SkinBlock {
                    Text("More sizes come from a file for this model of display, written with your administrator password. Turn on Scaling through overrides in Settings, under Advanced.")
                        .font(Skin.type.caption)
                        .foregroundStyle(Skin.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SkinBlock {
                    ScalingFacts(scaling: scaling)
                    if !scaling.installed.isEmpty {
                        SkinRule()
                        InstalledSizes(outcomes: scaling.installed)
                    }
                    if scaling.hasWaiting {
                        SkinRule()
                        WaitingSizes(scaling: scaling)
                    }
                    SkinRule()
                    ScalingActions(scaling: scaling, advanced: advanced)
                }
            }
        }
    }
}

struct ScalingFacts: View {
    let scaling: AdvancedPanelModel.Scaling

    private var line: String {
        var parts = ["\(scaling.hiDPIOffered) HiDPI sizes offered now"]
        if let panel = scaling.panel { parts.insert("Panel \(panel)", at: 0) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.xxs) {
            Text(verbatim: line).font(Skin.type.body).foregroundStyle(Skin.color.text)
            if !scaling.alsoReaches.isEmpty {
                Text(verbatim: "The file is for the model, so it also reaches " + scaling.alsoReaches.joined(separator: ", ") + ".")
                    .font(Skin.type.caption).foregroundStyle(Skin.color.attention).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(scaling.installedFacts, id: \.self) { (fact: String) in
                Text(verbatim: fact).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary)
            }
        }
    }
}

/// Each size the installed file asks for, and whether macOS offers it.
struct InstalledSizes: View {
    let outcomes: [SizeOutcome]

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.s) {
            ForEach(outcomes, id: \.size) { (outcome: SizeOutcome) in
                if outcome.offered {
                    OfferedRow(label: outcome.size.label)
                } else {
                    WhyRow(title: outcome.size.label, reason: "Written, and left out by macOS. It does not say why.")
                }
            }
        }
    }
}

struct OfferedRow: View {
    let label: String

    var body: some View {
        HStack(spacing: Skin.space.l) {
            Image(systemName: Skin.symbol.confirmed).font(Skin.type.symbol).foregroundStyle(Skin.color.accent).frame(width: Skin.size.whyMark).accessibilityHidden(true)
            Text(verbatim: label).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text)
            Spacer(minLength: Skin.space.s)
            MarkTag(text: "Offered", help: "macOS offers this size. Choose it on the size strip.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), offered by macOS")
    }
}

struct WaitingSizes: View {
    let scaling: AdvancedPanelModel.Scaling

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.xs) {
            HStack(spacing: Skin.space.m) {
                Text("Waiting to be written").font(Skin.type.captionStrong).foregroundStyle(Skin.color.textSecondary)
                Spacer(minLength: Skin.space.s)
                MarkTag(text: "Not written", help: "Nothing has been written yet. The preview shows what will be.")
            }
            Text(verbatim: scaling.waiting.isEmpty ? "Nothing" : scaling.waiting.joined(separator: ", "))
                .font(Skin.type.body).foregroundStyle(Skin.color.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ScalingActions: View {
    let scaling: AdvancedPanelModel.Scaling
    @ObservedObject var advanced: AdvancedPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.m) {
            HStack(spacing: Skin.space.s) {
                Button("Add Fine Steps") { advanced.stage("flexible 50-100/5", tag: scaling.tag) }.buttonStyle(QuietStyle())
                Button("Add a Size…") { advanced.addSizePrompt(tag: scaling.tag) }.buttonStyle(QuietStyle())
                if scaling.hasWaiting {
                    Button("Forget") { advanced.discardWaiting(tag: scaling.tag) }.buttonStyle(QuietStyle())
                }
            }
            .disabled(!advanced.overridesEnabled)
            if scaling.hasWaiting {
                Button("Preview and Write…") { advanced.previewWaiting() }.buttonStyle(ProminentStyle())
            }
            if !scaling.installed.isEmpty {
                HStack(spacing: Skin.space.s) {
                    Button("Reconnect to Finish") { advanced.activate(tag: scaling.tag) }.buttonStyle(QuietStyle()).disabled(scaling.isMain)
                    Button("Undo…") { advanced.previewUndo(tag: scaling.tag) }.buttonStyle(QuietStyle())
                    Button("Remove…") { advanced.previewRemoval(tag: scaling.tag) }.buttonStyle(QuietStyle())
                }
            }
            if scaling.isMain && !scaling.installed.isEmpty {
                CostLine(text: "This is the main display, so Display 16X does not reconnect it. Unplug and replug its cable, or log out and in, for macOS to read the file.")
            } else {
                CostLine(text: "Costs nothing once written. Writing asks for your administrator password, and the display goes dark for a few seconds while it reconnects.")
            }
        }
    }
}
