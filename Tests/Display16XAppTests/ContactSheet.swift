import AppKit
import SwiftUI

/// Several pictures side by side with their names, as one image, for comparing at a glance.
@MainActor
enum ContactSheet {
    struct Item {
        var caption: String
        var file: URL
    }

    struct Tile: View {
        let caption: String
        let image: NSImage
        let size: CGSize

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: caption)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .lineLimit(2)
                    .frame(width: size.width, alignment: .leading)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            }
        }
    }

    struct Sheet: View {
        let title: String
        let rows: [[(caption: String, image: NSImage, size: CGSize)]]

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                if !title.isEmpty {
                    Text(verbatim: title).font(.system(size: 18, weight: .bold)).foregroundStyle(Color.black)
                }
                ForEach(0..<rows.count, id: \.self) { row in
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(0..<rows[row].count, id: \.self) { column in
                            Tile(caption: rows[row][column].caption, image: rows[row][column].image, size: rows[row][column].size)
                        }
                    }
                }
            }
            .padding(20)
            .background(Color.white)
        }
    }

    /// - Parameter zoom: Points on the sheet per point of the original surface.
    static func write(_ items: [Item], title: String = "", columns: Int, zoom: CGFloat = 1, scale: CGFloat = 2, to url: URL) throws {
        var tiles: [(caption: String, image: NSImage, size: CGSize)] = []
        for item in items {
            guard let image = NSImage(contentsOf: item.file), let rep = image.representations.first else { continue }
            // The pictures are drawn at two pixels per point.
            let width = CGFloat(rep.pixelsWide) / 2 * zoom
            let height = CGFloat(rep.pixelsHigh) / 2 * zoom
            tiles.append((item.caption, image, CGSize(width: width, height: height)))
        }
        guard !tiles.isEmpty else { return }
        var rows: [[(caption: String, image: NSImage, size: CGSize)]] = []
        var index = 0
        while index < tiles.count {
            rows.append(Array(tiles[index..<min(index + columns, tiles.count)]))
            index += columns
        }
        let stage = Stage(Sheet(title: title, rows: rows), look: .light, active: false)
        guard let data = stage.png(scale: scale) else { return }
        try data.write(to: url)
    }
}
