//
//  SMC.swift
//  Fanatic
//
//  Read-only client for the Apple System Management Controller.
//  Mirrors AppleSMC's SMCKeyData_t wire format and talks to the kernel
//  service directly through IOKit: no root, no helper tool, no polling
//  of external processes.
//

import Foundation
import IOKit

/// A single decoded SMC value.
enum SMCValue {
    case number(Double)
    case unsupported(type: String)
}

final class SMC {

    // MARK: - Wire format

    // Layout must match AppleSMC's SMCKeyData_t exactly (80 bytes).
    // Swift lays struct fields out in declaration order; `padding` and the
    // 8-byte-aligned payload reproduce the C compiler's implicit padding.

    private struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    /// The 32-byte value buffer, expressed as four words so it stays readable.
    private struct Payload {
        var a: UInt64 = 0
        var b: UInt64 = 0
        var c: UInt64 = 0
        var d: UInt64 = 0
    }

    private struct ParamStruct {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var payload = Payload()
    }

    private enum Selector {
        static let handleYPCEvent: UInt32 = 2
    }

    private enum Command {
        static let readKey: UInt8 = 5
        static let getKeyInfo: UInt8 = 9
        static let getKeyFromIndex: UInt8 = 8
    }

    // MARK: - Connection

    private var connection: io_connect_t = IO_OBJECT_NULL
    private var keyInfoCache: [UInt32: KeyInfo] = [:]

    init?() {
        guard MemoryLayout<ParamStruct>.stride == 80 else {
            assertionFailure("SMCKeyData_t layout drifted: \(MemoryLayout<ParamStruct>.stride) bytes")
            return nil
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
        connection = conn
    }

    deinit {
        if connection != IO_OBJECT_NULL { IOServiceClose(connection) }
    }

    // MARK: - Raw access

    private func call(_ input: ParamStruct) -> ParamStruct? {
        var input = input
        var output = ParamStruct()
        var outputSize = MemoryLayout<ParamStruct>.stride

        let result = IOConnectCallStructMethod(connection,
                                               Selector.handleYPCEvent,
                                               &input,
                                               MemoryLayout<ParamStruct>.stride,
                                               &output,
                                               &outputSize)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func info(for key: UInt32) -> KeyInfo? {
        if let cached = keyInfoCache[key] { return cached }

        var input = ParamStruct()
        input.key = key
        input.data8 = Command.getKeyInfo
        guard let output = call(input) else { return nil }

        keyInfoCache[key] = output.keyInfo
        return output.keyInfo
    }

    /// Reads a four-character SMC key and decodes it as a number.
    /// Returns nil when the key does not exist on this machine.
    func read(_ key: String) -> SMCValue? {
        let fourCC = SMC.fourCharCode(key)
        guard let keyInfo = info(for: fourCC) else { return nil }

        var input = ParamStruct()
        input.key = fourCC
        input.keyInfo = keyInfo
        input.data8 = Command.readKey
        guard let output = call(input) else { return nil }

        let size = Int(keyInfo.dataSize)
        let bytes = withUnsafeBytes(of: output.payload) { Array($0.prefix(size)) }
        return SMC.decode(bytes, type: keyInfo.dataType)
    }

    /// Convenience: reads a key already known to hold a number.
    func readNumber(_ key: String) -> Double? {
        if case .number(let value) = read(key) { return value }
        return nil
    }

    /// Resolves the key stored at `index` in the SMC's key table.
    func key(at index: Int) -> String? {
        var input = ParamStruct()
        input.data8 = Command.getKeyFromIndex
        input.data32 = UInt32(index)
        guard let output = call(input) else { return nil }
        return SMC.typeName(output.key)
    }

    // MARK: - Decoding

    private static func decode(_ bytes: [UInt8], type: UInt32) -> SMCValue {
        let name = typeName(type)

        switch name {
        case "flt ":
            guard bytes.count >= 4 else { break }
            // Floats are little-endian, unlike the integer types below.
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return .number(Double(Float(bitPattern: bits)))

        case "ui8 ", "ui16", "ui32", "ui64":
            return .number(Double(bigEndianUnsigned(bytes)))

        case "si8 ", "si16", "si32":
            let raw = bigEndianUnsigned(bytes)
            let bits = bytes.count * 8
            // Sign-extend from the key's own width.
            if bits < 64, raw & (1 << UInt64(bits - 1)) != 0 {
                return .number(Double(Int64(bitPattern: raw | ~((1 << UInt64(bits)) - 1))))
            }
            return .number(Double(raw))

        default:
            // Fixed-point families: fpXY / spXY, where Y is the number of
            // fractional bits expressed as a hex digit (fpe2 -> 2 fractional bits).
            if name.count == 4, name.hasPrefix("fp") || name.hasPrefix("sp"),
               let fraction = UInt32(String(name.suffix(1)), radix: 16) {
                return .number(Double(bigEndianUnsigned(bytes)) / Double(1 << fraction))
            }
        }
        return .unsupported(type: name)
    }

    private static func bigEndianUnsigned(_ bytes: [UInt8]) -> UInt64 {
        bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func fourCharCode(_ key: String) -> UInt32 {
        let scalars = Array(key.utf8)
        precondition(scalars.count == 4, "SMC keys are four characters: \(key)")
        return scalars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func typeName(_ type: UInt32) -> String {
        let bytes = [UInt8(type >> 24 & 0xFF), UInt8(type >> 16 & 0xFF),
                     UInt8(type >> 8 & 0xFF), UInt8(type & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Key enumeration (diagnostics)

extension SMC {
    /// Lists every key the SMC exposes. Used for sensor discovery, not on the hot path.
    func allKeys() -> [String] {
        guard let count = readNumber("#KEY").map({ Int($0) }) else { return [] }
        return (0..<count).compactMap { key(at: $0) }
    }
}
