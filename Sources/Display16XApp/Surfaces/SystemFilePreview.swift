import DisplayCore
import SwiftUI

/// What will be written outside the app's folder, shown whole before anything happens:
/// the displays it reaches, every step, what finishes it, and every byte of every file.
/// "Write as Administrator" is the only way on, and macOS then asks for the password.
struct SystemFilePreview: View {
    let plan: SystemFilePlan
    let confirm: () -> Void
    let cancel: () -> Void

    private var files: [(path: String, text: String)] {
        plan.steps.compactMap { step in
            if case .write(let path, let data) = step { return (path, String(decoding: data, as: UTF8.self)) }
            return nil
        }
    }

    var body: some View {
        WindowBody(width: Skin.size.previewWidth) {
            VStack(alignment: .leading, spacing: Skin.space.l) {
                Text(verbatim: plan.title).font(Skin.type.windowTitle).foregroundStyle(Skin.color.text).fixedSize(horizontal: false, vertical: true)
                if !plan.affected.isEmpty { PreviewAffected(affected: plan.affected) }
                PreviewSteps(steps: plan.steps)
                PreviewNotes(notes: plan.notes, finish: plan.finish)
                ForEach(files, id: \.path) { (file: (path: String, text: String)) in
                    PreviewFile(path: file.path, text: file.text)
                }
                HStack(spacing: Skin.space.m) {
                    Spacer()
                    Button("Cancel", action: cancel).buttonStyle(QuietStyle()).keyboardShortcut(.cancelAction)
                    Button("Write as Administrator…", action: confirm).buttonStyle(ProminentStyle())
                }
            }
        }
    }
}

struct PreviewAffected: View {
    let affected: [AffectedDisplay]

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.xxs) {
            SkinHeading(text: affected.count == 1 ? "The display it reaches" : "Every display it reaches")
            ForEach(affected, id: \.tag) { (display: AffectedDisplay) in
                Text(verbatim: display.name + (display.isConnected ? "" : ", not connected now"))
                    .font(Skin.type.body).foregroundStyle(Skin.color.text)
            }
        }
    }
}

struct PreviewSteps: View {
    let steps: [SystemFileStep]

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.xxs) {
            SkinHeading(text: "As administrator, in one step")
            ForEach(Array(steps.enumerated()), id: \.offset) { (item: (offset: Int, element: SystemFileStep)) in
                Text(verbatim: item.element.summary).font(Skin.type.mono).foregroundStyle(Skin.color.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}

struct PreviewNotes: View {
    let notes: [String]
    let finish: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.xs) {
            ForEach(notes, id: \.self) { (note: String) in
                Text(verbatim: note).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if let finish {
                Text(verbatim: finish).font(Skin.type.captionStrong).foregroundStyle(Skin.color.text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The file as it will be on disk.
struct PreviewFile: View {
    let path: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.xs) {
            SkinHeading(text: "The file, byte for byte")
            Text(verbatim: path).font(Skin.type.captionStrong).foregroundStyle(Skin.color.textSecondary).textSelection(.enabled)
            ScrollView(.vertical) {
                Text(verbatim: text).font(Skin.type.mono).foregroundStyle(Skin.color.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Skin.space.m)
            }
            .frame(maxHeight: Skin.size.mapHeight * 2)
            .background(Skin.color.canvas, in: RoundedRectangle(cornerRadius: Skin.radius.control, style: .continuous))
            .accessibilityLabel("The file \(path)")
        }
    }
}
