import Foundation

#if canImport(IOKit)
import IOKit

final class SMCClient {
    static let shared = SMCClient()

    private let connection: io_connect_t
    private let connected: Bool

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            connection = 0
            connected = false
            return
        }

        var openedConnection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &openedConnection)
        IOObjectRelease(service)
        connection = openedConnection
        connected = result == kIOReturnSuccess
    }

    deinit {
        if connected {
            IOServiceClose(connection)
        }
    }

    func readTemperatures() -> [TemperatureReading] {
        guard connected else { return [] }
        return KnownSMCKeys.temperatureKeys.compactMap { key in
            guard let value = readSP78(key) else { return nil }
            return TemperatureReading(key: key, celsius: value)
        }
    }

    func readFans() -> [FanStatus] {
        guard connected else { return [] }
        let count = Int(readFPE2("FNum") ?? 0)
        guard count > 0 else { return [] }

        return (0..<count).map { index in
            let current = Int(readFPE2("F\(index)Ac") ?? 0)
            let minimum = Int(readFPE2("F\(index)Mn") ?? 1200)
            let maximum = Int(readFPE2("F\(index)Mx") ?? 7200)
            let target = readFPE2("F\(index)Tg").map(Int.init)
            return FanStatus(
                id: index,
                name: index == 0 ? "Left Fan" : index == 1 ? "Right Fan" : "Fan \(index + 1)",
                currentRPM: current,
                minimumRPM: minimum,
                maximumRPM: maximum,
                targetRPM: target
            )
        }
    }

    func setAutomaticFanControl() {
        guard connected else { return }
        writeUInt16("FS! ", value: 0)
    }

    func setFixedRPM(_ rpm: Int, for fan: FanStatus) {
        guard connected else { return }
        let bounded = rpm.clamped(to: fan.minimumRPM...fan.maximumRPM)
        writeFPE2("F\(fan.id)Tg", value: Double(bounded))
        writeUInt16("FS! ", value: UInt16(1 << fan.id))
    }

    private func readSP78(_ key: String) -> Double? {
        guard let bytes = readKey(key), bytes.count >= 2 else { return nil }
        let integer = Double(Int8(bitPattern: bytes[0]))
        let fraction = Double(bytes[1]) / 256.0
        return integer + fraction
    }

    private func readFPE2(_ key: String) -> Double? {
        guard let bytes = readKey(key), bytes.count >= 2 else { return nil }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return Double(raw) / 4.0
    }

    private func writeFPE2(_ key: String, value: Double) {
        let raw = UInt16((value * 4).rounded())
        writeKey(key, bytes: [UInt8(raw >> 8), UInt8(raw & 0xff)], dataType: "fpe2")
    }

    private func writeUInt16(_ key: String, value: UInt16) {
        writeKey(key, bytes: [UInt8(value >> 8), UInt8(value & 0xff)], dataType: "ui16")
    }

    private func readKey(_ key: String) -> [UInt8]? {
        var input = SMCKeyData(key: key.smcKey)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        var output = SMCKeyData()
        guard call(input: &input, output: &output) else { return nil }

        input = SMCKeyData(key: key.smcKey)
        input.keyInfo = output.keyInfo
        input.data8 = SMCCommand.readBytes.rawValue
        output = SMCKeyData()
        guard call(input: &input, output: &output) else { return nil }
        return Array(output.bytes.prefix(Int(input.keyInfo.dataSize)))
    }

    private func writeKey(_ key: String, bytes: [UInt8], dataType: String) {
        var input = SMCKeyData(key: key.smcKey)
        input.data8 = SMCCommand.writeBytes.rawValue
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.keyInfo.dataType = dataType.smcKey
        input.bytes = SMCBytes(bytes)
        var output = SMCKeyData()
        _ = call(input: &input, output: &output)
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> Bool {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = withUnsafeMutablePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                inputPointer.withMemoryRebound(to: UInt8.self, capacity: inputSize) { inputBytes in
                    outputPointer.withMemoryRebound(to: UInt8.self, capacity: outputSize) { outputBytes in
                        IOConnectCallStructMethod(
                            connection,
                            2,
                            inputBytes,
                            inputSize,
                            outputBytes,
                            &outputSize
                        )
                    }
                }
            }
        }
        return result == kIOReturnSuccess
    }
}

struct TemperatureReading {
    let key: String
    let celsius: Double
}

private enum SMCCommand: UInt8 {
    case readKeyInfo = 9
    case readBytes = 5
    case writeBytes = 6
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = SMCBytes()

    init(key: UInt32 = 0) {
        self.key = key
    }
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCBytes {
    var b0: UInt8 = 0
    var b1: UInt8 = 0
    var b2: UInt8 = 0
    var b3: UInt8 = 0
    var b4: UInt8 = 0
    var b5: UInt8 = 0
    var b6: UInt8 = 0
    var b7: UInt8 = 0
    var b8: UInt8 = 0
    var b9: UInt8 = 0
    var b10: UInt8 = 0
    var b11: UInt8 = 0
    var b12: UInt8 = 0
    var b13: UInt8 = 0
    var b14: UInt8 = 0
    var b15: UInt8 = 0
    var b16: UInt8 = 0
    var b17: UInt8 = 0
    var b18: UInt8 = 0
    var b19: UInt8 = 0
    var b20: UInt8 = 0
    var b21: UInt8 = 0
    var b22: UInt8 = 0
    var b23: UInt8 = 0
    var b24: UInt8 = 0
    var b25: UInt8 = 0
    var b26: UInt8 = 0
    var b27: UInt8 = 0
    var b28: UInt8 = 0
    var b29: UInt8 = 0
    var b30: UInt8 = 0
    var b31: UInt8 = 0

    init() {}

    init(_ bytes: [UInt8]) {
        var copy = bytes
        while copy.count < 32 { copy.append(0) }
        b0 = copy[0]; b1 = copy[1]; b2 = copy[2]; b3 = copy[3]
        b4 = copy[4]; b5 = copy[5]; b6 = copy[6]; b7 = copy[7]
        b8 = copy[8]; b9 = copy[9]; b10 = copy[10]; b11 = copy[11]
        b12 = copy[12]; b13 = copy[13]; b14 = copy[14]; b15 = copy[15]
        b16 = copy[16]; b17 = copy[17]; b18 = copy[18]; b19 = copy[19]
        b20 = copy[20]; b21 = copy[21]; b22 = copy[22]; b23 = copy[23]
        b24 = copy[24]; b25 = copy[25]; b26 = copy[26]; b27 = copy[27]
        b28 = copy[28]; b29 = copy[29]; b30 = copy[30]; b31 = copy[31]
    }

    func prefix(_ count: Int) -> [UInt8] {
        Array(all.prefix(count))
    }

    private var all: [UInt8] {
        [b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15,
         b16, b17, b18, b19, b20, b21, b22, b23, b24, b25, b26, b27, b28, b29, b30, b31]
    }
}

private extension String {
    var smcKey: UInt32 {
        unicodeScalars.prefix(4).reduce(UInt32(0)) { result, scalar in
            (result << 8) + UInt32(scalar.value)
        }
    }
}

enum KnownSMCKeys {
    static let temperatureKeys = [
        "TC0C", "TC0D", "TC0E", "TC0F", "TC0P", "TC1C", "TC2C", "TC3C", "TC4C", "TC5C", "TC6C", "TC7C",
        "TG0D", "TG0P", "TG1D", "TG1P", "TM0P", "TB0T", "Ts0P", "Ts1P", "TN0D", "Th0H", "Tp0P"
    ]

    static func displayName(for key: String) -> String {
        switch key {
        case "TC0C": return "CPU PECI"
        case "TC0D": return "CPU Diode"
        case "TC0P": return "CPU Proximity"
        case "TG0D": return "GPU Diode"
        case "TG0P": return "GPU Proximity"
        case "TM0P": return "Memory Proximity"
        case "TB0T": return "Battery"
        case "Ts0P": return "Palm Rest Left"
        case "Ts1P": return "Palm Rest Right"
        case "TN0D": return "Northbridge"
        case "Th0H": return "Heatpipe"
        case "Tp0P": return "Power Supply"
        default:
            if key.hasPrefix("TC") { return "CPU Core \(key.dropFirst(2).dropLast())" }
            if key.hasPrefix("TG") { return "GPU Sensor \(key.dropFirst(2).dropLast())" }
            return key
        }
    }

    static func group(for key: String) -> SensorGroup {
        if key.hasPrefix("TC") { return .cpu }
        if key.hasPrefix("TG") { return .gpu }
        if key.hasPrefix("TM") { return .memory }
        if key.hasPrefix("TB") { return .battery }
        if key.hasPrefix("Ts") || key.hasPrefix("Th") { return .enclosure }
        return .unknown
    }
}

#else

final class SMCClient {
    static let shared = SMCClient()
    func readTemperatures() -> [TemperatureReading] { [] }
    func readFans() -> [FanStatus] { [] }
    func setAutomaticFanControl() {}
    func setFixedRPM(_ rpm: Int, for fan: FanStatus) {}
}

struct TemperatureReading {
    let key: String
    let celsius: Double
}

enum KnownSMCKeys {
    static let temperatureKeys: [String] = []
    static func displayName(for key: String) -> String { key }
    static func group(for key: String) -> SensorGroup { .unknown }
}

#endif
