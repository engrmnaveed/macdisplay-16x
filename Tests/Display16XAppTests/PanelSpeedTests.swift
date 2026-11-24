import AppKit
import SwiftUI
import Testing
@testable import Display16XApp
@testable import DisplayCore

/// How long the panel's content takes to build: the two models, the views and their first
/// layout, on the sample desk and off screen. It is a stand-in for the budget "the panel
/// opens in under 100 ms warm", which is about the real app on screen and is measured
/// there. Run it with `DISPLAY16X_MEASURE=1 swift test -c release --filter PanelSpeed`.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PanelSpeed {
    static func buildOnce(_ desk: SampleDesk, route: PanelRoute) -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        let model = PanelModel(context: desk.context)
        let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
        let hosting = NSHostingController(rootView: PanelView(model: model, layoutModel: layoutModel, start: route, openSettings: {}, quit: {}))
        hosting.sizingOptions = [.preferredContentSize]
        _ = hosting.view.fittingSize
        hosting.view.layoutSubtreeIfNeeded()
        let elapsed = clock.now - start
        model.close()
        layoutModel.close()
        return elapsed
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test func build() async throws {
        guard ProcessInfo.processInfo.environment["DISPLAY16X_MEASURE"] != nil else { return }
        _ = NSApplication.shared
        let desk = try await SurfaceCatalog.livedIn()
        let lg = desk.tag(SampleDesk.lgID)
        for (name, route) in [("displays", PanelRoute.home), ("one display's page", .display(lg)), ("arrange", .arrange)] {
            for _ in 0..<5 { _ = PanelSpeed.buildOnce(desk, route: route) }
            let runs: [Double] = (0..<40).map { _ in PanelSpeed.milliseconds(PanelSpeed.buildOnce(desk, route: route)) }.sorted()
            let median: Double = runs[runs.count / 2]
            let worst: Double = runs[runs.count - 1]
            print(String(format: "panel build, %@: median %.1f ms, worst %.1f ms, 40 runs", name, median, worst))
            #expect(median < 100, "the panel's content took \(median) ms to build")
        }
    }
}
