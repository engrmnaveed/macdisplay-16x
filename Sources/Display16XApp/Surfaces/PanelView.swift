import DisplayCore
import SwiftUI

/// Which page the panel shows. The panel is one column, and a page takes its place: the
/// panel never grows sideways or downwards with what is opened.
enum PanelRoute: Equatable {
    case home
    case display(DisplayTag)
    case arrange
}

/// The panel under the menu bar item.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var layoutModel: LayoutPanelModel
    /// The panel scrolls inside this height instead of growing past it.
    var maxHeight: CGFloat = Skin.size.panelMaxHeight
    let openSettings: () -> Void
    let quit: () -> Void
    /// v0.3: more sizes on a display's page. Nil leaves the panel as it was.
    let advanced: AdvancedPanelModel?
    private let route: State<PanelRoute>

    init(
        model: PanelModel, layoutModel: LayoutPanelModel, maxHeight: CGFloat = Skin.size.panelMaxHeight, start: PanelRoute = .home,
        advanced: AdvancedPanelModel? = nil, openSettings: @escaping () -> Void, quit: @escaping () -> Void
    ) {
        self.model = model
        self.layoutModel = layoutModel
        self.advanced = advanced
        self.maxHeight = maxHeight
        self.openSettings = openSettings
        self.quit = quit
        route = State(initialValue: start)
    }

    private func go(_ next: PanelRoute) {
        route.wrappedValue = next
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.l) {
            PanelNotices(model: model, layoutModel: layoutModel)
            ViewThatFits(in: .vertical) {
                page
                ScrollView(.vertical) { page }
            }
            PanelFooter(route: route.wrappedValue, arrange: { go(route.wrappedValue == .arrange ? .home : .arrange) }, openSettings: openSettings, quit: quit)
        }
        .padding(Skin.space.xl)
        .frame(width: Skin.size.panelWidth)
        .frame(maxHeight: maxHeight)
        .background(Skin.color.canvas)
        .tint(Skin.color.accent)
    }

    @ViewBuilder private var page: some View {
        switch route.wrappedValue {
        case .display(let tag):
            if let card = model.cards.first(where: { $0.tag == tag }) {
                DisplayDetail(card: card, item: layoutModel.items.first { $0.tag == tag }, model: model, layoutModel: layoutModel, back: { go(.home) }, advanced: advanced)
            } else {
                home
            }
        case .arrange:
            ArrangePage(model: model, layoutModel: layoutModel, back: { go(.home) }, open: { go(.display($0)) })
        case .home:
            home
        }
    }

    private var home: some View {
        HomePage(model: model, layoutModel: layoutModel, open: { go(.display($0)) }, arrange: { go(.arrange) })
    }
}

// MARK: Home

/// Scenes, then one card per display.
struct HomePage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var layoutModel: LayoutPanelModel
    let open: (DisplayTag) -> Void
    let arrange: () -> Void

    private var awayCount: Int {
        let away: Set<DisplayTag> = Set(layoutModel.away.map(\.tag))
        return away.union(model.remembered.map(\.tag)).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.l) {
            if !model.cards.isEmpty || !layoutModel.presets.isEmpty {
                ScenesRow(layoutModel: layoutModel)
            }
            if model.cards.isEmpty {
                EmptyDesk()
            }
            ForEach(model.cards) { card in
                DisplayCard(card: card, model: model, open: { open(card.tag) })
            }
            if awayCount > 0 {
                Button(action: arrange) {
                    Text(verbatim: awayCount == 1 ? "1 display is off or away" : "\(awayCount) displays are off or away")
                }
                .buttonStyle(TextLinkStyle())
                .padding(.leading, Skin.space.xs)
            }
        }
    }
}

struct EmptyDesk: View {
    var body: some View {
        SkinBlock {
            HStack(alignment: .top, spacing: Skin.space.l) {
                Image(systemName: Skin.symbol.noDisplay).font(Skin.type.title).foregroundStyle(Skin.color.textSecondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Skin.space.xs) {
                    Text("No display is connected").font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text)
                    Text("Controls appear here when a display is plugged in or the lid is opened.")
                        .font(Skin.type.caption)
                        .foregroundStyle(Skin.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: Notices

/// What the user should not miss, above everything else: safe mode, a first greeting, a
/// permission that is missing, the recorder waiting for keys, and the last thing that failed.
struct PanelNotices: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var layoutModel: LayoutPanelModel

    var body: some View {
        if model.isSafeMode {
            Banner(
                kind: .attention, symbol: Skin.symbol.safeMode, title: "Safe mode",
                message: "Nothing is restored or put back by itself. It ends when you quit Display 16X and open it again."
            )
        }
        if model.isFirstRun {
            Banner(
                kind: .note, symbol: Skin.symbol.confirmed, title: "Display 16X is in your menu bar",
                message: "Open this panel from its icon. Nothing about your displays changes until you change it here."
            )
        }
        ForEach(model.advice) { advice in
            PermissionBanner(topic: advice.topic, didNotTake: model.accessibilityDidNotTake, model: model)
        }
        if layoutModel.pending {
            Banner(kind: .note, symbol: Skin.symbol.arrange, title: "Keep this arrangement?", message: "It goes back by itself if you do not answer.") {
                HStack(spacing: Skin.space.m) {
                    Button("Revert") { layoutModel.revert() }.buttonStyle(QuietStyle())
                    Button("Keep") { layoutModel.keep() }.buttonStyle(ProminentStyle())
                }
            }
        }
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

/// The one thing the user has to do for a feature to work, with the button that does it.
struct PermissionBanner: View {
    let topic: PermissionAdvice.Topic
    let didNotTake: Bool
    @ObservedObject var model: PanelModel

    var body: some View {
        switch topic {
        case .accessibility:
            if didNotTake {
                Banner(
                    kind: .attention, symbol: Skin.symbol.keys, title: "The keys still have no permission",
                    message: "An entry left by an older copy of Display 16X can look switched on and not count. In System Settings, under Accessibility:\n1. Select Display 16X in the list and remove it with the minus button.\n2. Add this copy with the plus button and switch it on.\n3. Open this panel again."
                ) {
                    Button("Open Accessibility Settings") { model.requestAccessibility() }.buttonStyle(ProminentStyle())
                }
            } else {
                Banner(
                    kind: .attention, symbol: Skin.symbol.keys, title: "Let the brightness and volume keys work",
                    message: "macOS asks for the Accessibility permission before an app may read those keys. Display 16X uses it for nothing else."
                ) {
                    Button("Open Accessibility Settings") { model.requestAccessibility() }.buttonStyle(ProminentStyle())
                }
            }
        case .loginItem:
            Banner(
                kind: .attention, symbol: Skin.symbol.loginItem, title: "Opening at login is waiting for you",
                message: "Allow Display 16X under Login Items in System Settings."
            ) {
                Button("Open Login Items") { model.openLoginItems() }.buttonStyle(ProminentStyle())
            }
        }
    }
}

// MARK: Footer

struct PanelFooter: View {
    let route: PanelRoute
    let arrange: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        HStack(spacing: Skin.space.s) {
            Wordmark()
            Spacer()
            Button(action: arrange) {
                Label(route == .arrange ? "Displays" : "Arrange", systemImage: route == .arrange ? Skin.symbol.back : Skin.symbol.arrange)
            }
            .buttonStyle(ChipStyle())
            Button(action: openSettings) {
                Label("Settings", systemImage: Skin.symbol.settings)
            }
            .buttonStyle(ChipStyle())
            Button(action: quit) {
                Image(systemName: Skin.symbol.quit)
            }
            .buttonStyle(RoundStyle())
            .keyboardShortcut("q")
            .help("Quit Display 16X")
            .accessibilityLabel("Quit Display 16X")
        }
        .labelStyle(.titleAndIcon)
    }
}
