import Foundation

enum LengthUnit: String, Codable, CaseIterable, Identifiable {
    case meters, centimeters, millimeters, inches

    var id: String { rawValue }

    var millimeters: Float {
        switch self {
        case .meters: return 1000
        case .centimeters: return 10
        case .millimeters: return 1
        case .inches: return 25.4
        }
    }

    var title: String {
        switch self {
        case .meters: return "Meters"
        case .centimeters: return "Centimeters"
        case .millimeters: return "Millimeters"
        case .inches: return "Inches"
        }
    }
}

enum UpAxis: String, Codable, CaseIterable, Identifiable {
    case y, z

    var id: String { rawValue }
    var title: String { self == .y ? "Y up" : "Z up" }
}

/// Everything that controls how a raw scan is turned into a printable part.
struct PrintSettings: Codable, Hashable {
    enum Sizing: String, Codable, CaseIterable, Identifiable {
        case realSize, fitLongestSide

        var id: String { rawValue }
        var title: String { self == .realSize ? "Real size" : "Fit to size" }
    }

    /// Units and orientation of the source file. Scans from this app are in
    /// meters with Y up (ARKit / RealityKit convention).
    var sourceUnit: LengthUnit = .meters
    var sourceUpAxis: UpAxis = .y

    var sizing: Sizing = .realSize
    /// Scale applied in `.realSize` mode, in percent.
    var scalePercent: Double = 100
    /// Longest side of the printed part in `.fitLongestSide` mode.
    var targetLongestSideMM: Double = 80

    var fillHoles = true
    var removeFloaters = true
    var keepLargestPartOnly = false
    /// Slices this much off the bottom to give the part a flat base that
    /// sticks to the print bed. Zero disables the cut.
    var flatBaseCutMM: Double = 0

    static func defaults(for method: ScanMethod) -> PrintSettings {
        var settings = PrintSettings()
        switch method {
        case .objectCapture:
            break
        case .lidar:
            // ARKit meshes are noisy: keep only the main object.
            settings.keepLargestPartOnly = true
            settings.flatBaseCutMM = 1
        case .imported:
            settings.removeFloaters = false
        }
        return settings
    }
}
