import AppKit
import Foundation

/// Compares two folders of pictures made by the harness, file by file.
@MainActor
enum RenderComparison {
    struct Report {
        var text: String
        var different: [String]
    }

    struct Difference {
        var pixels: Int
        var total: Int
        /// The rows and columns that hold every differing pixel, in points.
        var box: CGRect
    }

    static func compare(before: URL, after: URL, tolerance: Int = 10) throws -> Report {
        let manager = FileManager.default
        let names = Set(try manager.contentsOfDirectory(atPath: before.path) + manager.contentsOfDirectory(atPath: after.path))
            .filter { $0.hasSuffix(".png") || $0.hasSuffix(".ax.txt") }.sorted()
        var lines: [String] = []
        var different: [String] = []
        var same = 0
        for name in names {
            let old = before.appendingPathComponent(name)
            let new = after.appendingPathComponent(name)
            guard manager.fileExists(atPath: old.path) else { lines.append("only after:  \(name)"); different.append(name); continue }
            guard manager.fileExists(atPath: new.path) else { lines.append("only before: \(name)"); different.append(name); continue }
            if name.hasSuffix(".txt") {
                let first = try String(contentsOf: old, encoding: .utf8)
                let second = try String(contentsOf: new, encoding: .utf8)
                if first == second { same += 1 } else {
                    lines.append("differs:     \(name) (what VoiceOver is given)")
                    different.append(name)
                }
                continue
            }
            guard let first = bitmap(old), let second = bitmap(new) else { lines.append("unreadable:  \(name)"); continue }
            if first.pixelsWide != second.pixelsWide || first.pixelsHigh != second.pixelsHigh {
                lines.append("size:        \(name) \(first.pixelsWide / 2)×\(first.pixelsHigh / 2) → \(second.pixelsWide / 2)×\(second.pixelsHigh / 2) points")
                different.append(name)
                continue
            }
            if let difference = difference(first, second, tolerance: tolerance) {
                let share = Double(difference.pixels) / Double(difference.total) * 100
                let box = difference.box
                lines.append(String(format: "differs:     %@ %.2f%% of pixels, inside x %d–%d, y %d–%d points", name, share, Int(box.minX), Int(box.maxX), Int(box.minY), Int(box.maxY)))
                different.append(name)
            } else {
                same += 1
            }
        }
        lines.insert("\(names.count) files compared, \(same) the same, \(different.count) different.", at: 0)
        return Report(text: lines.joined(separator: "\n"), different: different)
    }

    static func bitmap(_ url: URL) -> NSBitmapImageRep? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    static func difference(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep, tolerance: Int) -> Difference? {
        guard let a = first.bitmapData, let b = second.bitmapData else { return nil }
        let width = first.pixelsWide
        let height = first.pixelsHigh
        let samples = first.samplesPerPixel
        guard samples == second.samplesPerPixel, first.bytesPerRow == second.bytesPerRow else {
            return Difference(pixels: width * height, total: width * height, box: CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        var count = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * first.bytesPerRow
            for x in 0..<width {
                let offset = row + x * samples
                var differs = false
                for sample in 0..<samples where abs(Int(a[offset + sample]) - Int(b[offset + sample])) > tolerance {
                    differs = true
                    break
                }
                if differs {
                    count += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard count > 0 else { return nil }
        return Difference(pixels: count, total: width * height, box: CGRect(x: minX / 2, y: minY / 2, width: (maxX - minX) / 2 + 1, height: (maxY - minY) / 2 + 1))
    }
}
