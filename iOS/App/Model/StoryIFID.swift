import Foundation

/// Treaty of Babel IFIDs for IFDB lookups (aligned with babel zcode/glulx/blorb).
enum StoryIFID {
    /// Z-machine story format byte (1–8), if this file is Z-code.
    static func zMachineVersion(for game: GameRecord) -> Int? {
        guard game.format == .zcode,
              let data = try? Data(contentsOf: game.fileURL, options: .mappedIfSafe) else { return nil }
        if data.starts(with: Data("FORM".utf8)), let exec = BlorbReader(data: data)?.executableData {
            return zMachineVersion(in: exec)
        }
        return zMachineVersion(in: data)
    }

    private static func zMachineVersion(in data: Data) -> Int? {
        guard !data.isEmpty else { return nil }
        let version = Int(data[0])
        return (1...8).contains(version) ? version : nil
    }

    static func ifids(from data: Data, format: GameFormat) -> [String] {
        switch format {
        case .unsupported:
            return []
        case .glulx:
            if data.starts(with: Array("Glul".utf8)) { return glulxIFIDs(data) }
            if data.starts(with: Array("FORM".utf8)) { return blorbIFIDs(data) }
            return glulxIFIDs(data)
        case .zcode:
            if data.starts(with: Array("FORM".utf8)) { return blorbIFIDs(data) }
            return zcodeIFIDs(data)
        }
    }

    private static func blorbIFIDs(_ data: Data) -> [String] {
        guard let blorb = BlorbReader(data: data) else { return [] }
        let fromMetadata = blorb.ifidsFromMetadata
        if !fromMetadata.isEmpty { return fromMetadata }
        guard let exec = blorb.executableData, let kind = blorb.executableType else { return [] }
        if kind == "ZCOD" { return zcodeIFIDs(exec) }
        if kind == "GLUL" { return glulxIFIDs(exec) }
        return []
    }

    private static func findUUIDMarker(_ data: Data) -> String? {
        let marker = Array("UUID://".utf8)
        guard data.count > marker.count + 10 else { return nil }
        for start in 0..<(data.count - marker.count) {
            guard data.subdata(in: start..<(start + marker.count)) == Data(marker) else { continue }
            var end = start + marker.count
            while end < data.count {
                let ch = data[end]
                let ok = (ch >= 0x30 && ch <= 0x39) || (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || ch == 0x2D
                if !ok { break }
                end += 1
            }
            guard end + 1 < data.count, data[end] == 0x2F, data[end + 1] == 0x2F else { continue }
            let raw = data.subdata(in: (start + marker.count)..<end)
            return String(decoding: raw.map { ($0 >= 0x61 && $0 <= 0x7A) ? $0 - 0x20 : $0 }, as: UTF8.self)
        }
        return nil
    }

    private static func zcodeIFIDs(_ data: Data) -> [String] {
        guard data.count >= 0x1E, (1...8).contains(Int(data[0])) else { return [] }
        if let uuid = findUUIDMarker(data) { return [uuid] }
        var serial = String(bytes: [UInt8](data.subdata(in: 0x12..<0x18)), encoding: .isoLatin1) ?? "000000"
        // Z-machine header: release @ $02, serial @ $12, checksum @ $1c (same as babel/zcode.c).
        let release = Int((UInt16(data[2]) << 8) | UInt16(data[3]))
        let checksum = Int((UInt16(data[0x1C]) << 8) | UInt16(data[0x1D]))
        serial = sanitizeSerial(serial)
        var ids: [String] = []
        if serial != "000000", let first = serial.first, first.isNumber, first != "8" {
            ids.append(String(format: "ZCODE-%d-%@-%04X", release, serial, checksum))
            ids.append(String(format: "ZCODE-%d-%@", release, serial))
        } else {
            ids.append(String(format: "ZCODE-%d-%@", release, serial))
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func glulxIFIDs(_ data: Data) -> [String] {
        guard data.count >= 256, data.starts(with: Array("Glul".utf8)) else { return [] }
        if let uuid = findUUIDMarker(data) { return [uuid] }
        let serialWord = readBE32(data, 32)
        let serialWord2 = readBE32(data, 12)
        if data.count >= 58, data.subdata(in: 36..<40) == Data("Info".utf8) {
            let bb = 52
            guard data.count >= bb + 8 else { return [] }
            let release = Int(readBE16(data, bb))
            var serial = String(bytes: [UInt8](data.subdata(in: (bb + 2)..<(bb + 8))), encoding: .isoLatin1) ?? "000000"
            serial = sanitizeSerial(serial)
            return [String(format: "GLULX-%u-%@-%04X", release, serial, serialWord)]
        }
        return [String(format: "GLULX-%08X-%08X", serialWord2, serialWord)]
    }

    private static func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private static func readBE16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func sanitizeSerial(_ serial: String) -> String {
        String(serial.map { ch -> Character in
            guard let scalar = ch.unicodeScalars.first, scalar.isASCII, ch.isLetter || ch.isNumber else { return "-" }
            return ch
        })
    }
}
