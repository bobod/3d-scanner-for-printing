import Foundation

/// Tiny ZIP archive writer, enough to build 3MF packages. Entries are
/// deflated with Apple's built-in raw DEFLATE encoder when that saves space.
struct ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let method: UInt16
        let offset: UInt32
    }

    private var archive = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        dosDate = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    mutating func add(path: String, data: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)

        var payload = data
        var method: UInt16 = 0
        if let deflated = try? (data as NSData).compressed(using: .zlib) as Data, deflated.count < data.count {
            payload = deflated
            method = 8
        }

        let offset = UInt32(archive.count)
        archive.appendLE(UInt32(0x04034b50))
        archive.appendLE(UInt16(20))          // version needed
        archive.appendLE(UInt16(0x0800))      // flags: UTF-8 names
        archive.appendLE(method)
        archive.appendLE(dosTime)
        archive.appendLE(dosDate)
        archive.appendLE(crc)
        archive.appendLE(UInt32(payload.count))
        archive.appendLE(UInt32(data.count))
        archive.appendLE(UInt16(name.count))
        archive.appendLE(UInt16(0))           // extra field length
        archive.append(name)
        archive.append(payload)

        entries.append(Entry(name: name, crc: crc, compressedSize: UInt32(payload.count),
                             uncompressedSize: UInt32(data.count), method: method, offset: offset))
    }

    func finalize() -> Data {
        var output = archive
        let directoryOffset = UInt32(output.count)
        for e in entries {
            output.appendLE(UInt32(0x02014b50))
            output.appendLE(UInt16(20))       // version made by
            output.appendLE(UInt16(20))       // version needed
            output.appendLE(UInt16(0x0800))
            output.appendLE(e.method)
            output.appendLE(dosTime)
            output.appendLE(dosDate)
            output.appendLE(e.crc)
            output.appendLE(e.compressedSize)
            output.appendLE(e.uncompressedSize)
            output.appendLE(UInt16(e.name.count))
            output.appendLE(UInt16(0))        // extra
            output.appendLE(UInt16(0))        // comment
            output.appendLE(UInt16(0))        // disk number
            output.appendLE(UInt16(0))        // internal attributes
            output.appendLE(UInt32(0))        // external attributes
            output.appendLE(e.offset)
            output.append(e.name)
        }
        let directorySize = UInt32(output.count) - directoryOffset
        output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt16(entries.count))
        output.appendLE(directorySize)
        output.appendLE(directoryOffset)
        output.appendLE(UInt16(0))
        return output
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            for byte in raw {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }
}
