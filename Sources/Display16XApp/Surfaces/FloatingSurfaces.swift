import DisplayCore
import SwiftUI

// What the app shows outside the panel: the indicator for a key, Keep or Revert on the
// affected display, a protection notice, and the offer to protect an arrangement.

// MARK: Indicator

/// Which display a key reached, and where the value stands on its sixteen steps.
struct IndicatorView: View {
    let payload: IndicatorPayload
    let name: String

    private var symbol: String {
        if payload.control == .brightness { return Skin.symbol.brightness }
        return payload.isMuted ? Skin.symbol.volumeMuted : Skin.symbol.volume
    }

    private var value: String {
        payload.isMuted ? "Muted" : PanelText.percent(payload.value)
    }

    var body: some View {
        HUD(width: Skin.size.hudWidth) {
            HStack(spacing: Skin.space.xl) {
                Image(systemName: symbol).font(Skin.type.hudSymbol).foregroundStyle(Skin.color.hudAccent)
                VStack(alignment: .leading, spacing: Skin.space.xs) {
                    HStack {
                        Text(verbatim: name).font(Skin.type.captionStrong).foregroundStyle(Skin.color.hudTextSecondary).lineLimit(1)
                        Spacer()
                        Text(verbatim: value).font(Skin.type.valueSmall).foregroundStyle(Skin.color.hudText)
                    }
                    SegmentMeter(filled: payload.filledSegments, count: payload.segments)
                }
            }
        }
        .padding(Skin.space.s)
    }
}

// MARK: Keep or Revert

/// Keep or Revert for a size, refresh rate or rotation, on the display that changed.
struct ConfirmationWindowView: View {
    let name: String
    /// "Keep 2560 × 1440?"
    let question: String
    /// What it goes back to: "3200 × 1800".
    let fallback: String
    let pending: PendingConfirmation
    let keep: () -> Void
    let revert: () -> Void

    var body: some View {
        WindowBody(width: Skin.size.keepWindowWidth) {
            HStack(alignment: .center, spacing: Skin.space.xxl) {
                CountdownRing(deadline: pending.deadline, seconds: pending.seconds)
                VStack(alignment: .leading, spacing: Skin.space.xs) {
                    Text(verbatim: question).font(Skin.type.windowTitle).foregroundStyle(Skin.color.text)
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

struct KeepButtons: View {
    let keep: () -> Void
    let revert: () -> Void

    var body: some View {
        HStack(spacing: Skin.space.m) {
            Spacer()
            Button("Revert", action: revert).buttonStyle(QuietStyle()).keyboardShortcut(.cancelAction)
            Button("Keep", action: keep).buttonStyle(ProminentStyle()).keyboardShortcut(.defaultAction)
        }
        .padding(.top, Skin.space.xs)
    }
}

/// Keep or Revert for an arrangement or a connection, with the desk as it is now.
struct LayoutConfirmationView: View {
    let pending: LayoutConfirmation
    /// The displays in use, for the small picture of the desk.
    var desk: [DeskMap.Entry] = []
    let keep: () -> Void
    let revert: () -> Void

    private var title: String {
        if pending.disconnected.isEmpty { return "Keep this arrangement?" }
        return pending.disconnected.count == 1 ? "Keep the display disconnected?" : "Keep the displays disconnected?"
    }

    var body: some View {
        WindowBody(width: Skin.size.keepWindowWidth) {
            HStack(alignment: .center, spacing: Skin.space.xxl) {
                CountdownRing(deadline: pending.deadline, seconds: pending.seconds)
                VStack(alignment: .leading, spacing: Skin.space.xs) {
                    HStack(alignment: .top) {
                        Text(verbatim: title).font(Skin.type.windowTitle).foregroundStyle(Skin.color.text).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Skin.space.m)
                        if desk.count > 1 {
                            DeskMap(entries: desk, size: Skin.size.miniMap, showsNames: false)
                        }
                    }
                    Text("The displays go back to how they were if you do not answer.")
                        .font(Skin.type.body)
                        .foregroundStyle(Skin.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    KeepButtons(keep: keep, revert: revert)
                }
            }
        }
    }
}

// MARK: Protection

/// A short line at the top of the main display when protection put something back, could
/// not, or stopped.
struct NoticeView: View {
    let notice: ProtectionNotice

    private var symbol: String {
        notice.kind == .restored ? Skin.symbol.restored : Skin.symbol.stopped
    }

    var body: some View {
        HUD(width: Skin.size.noticeWidth) {
            HStack(alignment: .top, spacing: Skin.space.l) {
                Image(systemName: symbol)
                    .font(Skin.type.title)
                    .foregroundStyle(notice.kind == .restored ? Skin.color.hudAccent : Skin.color.hudAttention)
                    .accessibilityHidden(true)
                Text(verbatim: PanelText.sentence(notice.message))
                    .font(Skin.type.body)
                    .foregroundStyle(Skin.color.hudText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Skin.space.s)
    }
}

/// Offered once, after the first arrangement change is kept.
struct ProtectionOfferView: View {
    let protect: () -> Void
    let notNow: () -> Void

    var body: some View {
        WindowBody(width: Skin.size.offerWidth) {
            HStack(alignment: .top, spacing: Skin.space.xxl) {
                Image(systemName: Skin.symbol.arrange).font(Skin.type.aboutName).foregroundStyle(Skin.color.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Skin.space.xs) {
                    Text("Put this arrangement back by itself?").font(Skin.type.windowTitle).foregroundStyle(Skin.color.text)
                    Text("Display 16X can put this arrangement, the main display and mirroring back after sleep, reconnects and changes made elsewhere. The switch is under Arrange.")
                        .font(Skin.type.body)
                        .foregroundStyle(Skin.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Skin.space.m) {
                        Spacer()
                        Button("Not Now", action: notNow).buttonStyle(QuietStyle()).keyboardShortcut(.cancelAction)
                        Button("Protect This Arrangement", action: protect).buttonStyle(ProminentStyle()).keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, Skin.space.xs)
                }
            }
        }
    }
}
