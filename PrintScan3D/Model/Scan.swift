import Foundation

enum ScanMethod: String, Codable {
    case objectCapture, lidar, imported

    var title: String {
        switch self {
        case .objectCapture: return "Object Capture"
        case .lidar: return "LiDAR Quick Scan"
        case .imported: return "Imported"
        }
    }

    var systemImage: String {
        switch self {
        case .objectCapture: return "camera.viewfinder"
        case .lidar: return "sensor.fill"
        case .imported: return "square.and.arrow.down"
        }
    }
}

struct Scan: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var method: ScanMethod
    /// File name of the raw model inside the scan's folder.
    var sourceFileName: String
    var printSettings: PrintSettings
}
