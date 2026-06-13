#if canImport(Combine)
import Foundation
import Combine
import Darwin

@MainActor
final class SensorStore: ObservableObject {
    @Published private(set) var probes: [TemperatureProbe] = []
    @Published private(set) var fans: [FanStatus] = []
    @Published private(set) var hardware = HardwareInfo()
    @Published var settings: AppSettings {
        didSet { persistSettings() }
    }
    @Published private(set) var safetyOverrideActive = false
    @Published private(set) var lastControlMessage = "Auto"

    private let smc: SMCClient
    private var timer: Timer?
    private var samples: [String: [TemperatureSample]] = [:]
    private var historicHighs: [String: Double] = [:]
    private let settingsURL: URL

    init(smc: SMCClient = .shared) {
        self.smc = smc
        settingsURL = Self.applicationSupportURL.appendingPathComponent("settings.json")
        settings = Self.loadSettings(from: settingsURL)
        refreshHardwareInfo()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    var hottestTemperature: Double? {
        probes.map(\.celsius).max()
    }

    var selectedCurve: FanCurve {
        settings.availableCurves.first { $0.id == settings.selectedCurveID } ?? FanCurve.templates[1]
    }

    func addCustomCurve(named name: String) {
        var copy = selectedCurve
        copy.id = UUID()
        copy.name = name.isEmpty ? "Custom Curve" : name
        copy.isTemplate = false
        settings.customCurves.append(copy)
        settings.selectedCurveID = copy.id
    }

    func deleteCustomCurve(_ curve: FanCurve) {
        settings.customCurves.removeAll { $0.id == curve.id && !$0.isTemplate }
        if settings.selectedCurveID == curve.id {
            settings.selectedCurveID = FanCurve.templates[1].id
        }
    }

    func updateSelectedCurve(_ curve: FanCurve) {
        guard !curve.isTemplate else {
            settings.selectedCurveID = curve.id
            return
        }
        if let index = settings.customCurves.firstIndex(where: { $0.id == curve.id }) {
            settings.customCurves[index] = curve
            settings.selectedCurveID = curve.id
        }
    }

    func refresh() {
        let readings = smc.readTemperatures()
        let now = Date()
        probes = readings.map { reading in
            let history = updatedHistory(for: reading.key, celsius: reading.celsius, now: now)
            let average = history.map(\.celsius).reduce(0, +) / Double(max(history.count, 1))
            let historicHigh = max(historicHighs[reading.key] ?? reading.celsius, reading.celsius)
            historicHighs[reading.key] = historicHigh
            return TemperatureProbe(
                id: reading.key,
                rawKey: reading.key,
                displayName: KnownSMCKeys.displayName(for: reading.key),
                group: KnownSMCKeys.group(for: reading.key),
                celsius: reading.celsius,
                average15s: average,
                historicHigh: historicHigh
            )
        }.sorted { lhs, rhs in
            if lhs.group.rawValue == rhs.group.rawValue { return lhs.displayName < rhs.displayName }
            return lhs.group.rawValue < rhs.group.rawValue
        }

        fans = smc.readFans()
        applyFanPolicy()
    }

    func refreshHardwareInfo() {
        hardware = HardwareInfo(
            cpuName: Sysctl.string(for: "machdep.cpu.brand_string") ?? ProcessInfo.processInfo.hostName,
            cpuCoreCount: Sysctl.integer(for: "hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount,
            gpuCoreCount: GPUInfo.detectCoreCount()
        )
    }

    private func updatedHistory(for key: String, celsius: Double, now: Date) -> [TemperatureSample] {
        var history = samples[key, default: []]
        history.append(TemperatureSample(date: now, celsius: celsius))
        history.removeAll { now.timeIntervalSince($0.date) > 15 }
        samples[key] = history
        return history
    }

    private func applyFanPolicy() {
        guard !fans.isEmpty else {
            lastControlMessage = "Waiting for SMC fan data"
            return
        }

        let currentMax = hottestTemperature ?? 0
        if settings.safeSystemEnabled && currentMax >= settings.safeTemperatureCelsius {
            safetyOverrideActive = true
            switch settings.safeOverrideMode {
            case .fullBlast:
                fans.forEach { smc.setFixedRPM($0.maximumRPM, for: $0) }
                lastControlMessage = "Safety override: Full Blast at \(currentMax.formattedTemperature)"
            case .automatic:
                smc.setAutomaticFanControl()
                lastControlMessage = "Safety override: Auto at \(currentMax.formattedTemperature)"
            }
            return
        }

        safetyOverrideActive = false
        switch settings.fanMode {
        case .automatic:
            smc.setAutomaticFanControl()
            lastControlMessage = "Auto"
        case .customRPM:
            fans.forEach { smc.setFixedRPM(settings.customRPM, for: $0) }
            lastControlMessage = "Custom RPM: \(settings.customRPM)"
        case .fullBlast:
            fans.forEach { smc.setFixedRPM($0.maximumRPM, for: $0) }
            lastControlMessage = "Full Blast"
        case .curve:
            guard let driverTemperature = temperature(for: selectedCurve.source) else {
                smc.setAutomaticFanControl()
                lastControlMessage = "Curve source unavailable, using Auto"
                return
            }
            fans.forEach { fan in
                let rpm = selectedCurve.rpm(
                    for: driverTemperature,
                    minimumRPM: fan.minimumRPM,
                    maximumRPM: fan.maximumRPM
                )
                smc.setFixedRPM(rpm, for: fan)
            }
            lastControlMessage = "\(selectedCurve.name): \(driverTemperature.formattedTemperature)"
        }
    }

    private func temperature(for source: CurveTemperatureSource) -> Double? {
        let cpu = probes.filter { $0.group == .cpu }
        let gpu = probes.filter { $0.group == .gpu }
        switch source {
        case .hottestCPUCore:
            return cpu.map(\.celsius).max()
        case .averageCPUCore:
            guard !cpu.isEmpty else { return nil }
            return cpu.map(\.celsius).reduce(0, +) / Double(cpu.count)
        case .averageGPU:
            guard !gpu.isEmpty else { return nil }
            return gpu.map(\.celsius).reduce(0, +) / Double(gpu.count)
        }
    }

    private func persistSettings() {
        do {
            try FileManager.default.createDirectory(
                at: Self.applicationSupportURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            lastControlMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    private static func loadSettings(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    private static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacFan", isDirectory: true)
    }
}

private struct TemperatureSample {
    let date: Date
    let celsius: Double
}

enum Sysctl {
    static func string(for key: String) -> String? {
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func integer(for key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

enum GPUInfo {
    static func detectCoreCount() -> Int? {
        if let metalFamily = Sysctl.string(for: "hw.optional.arm.FEAT_FP16") { _ = metalFamily }
        guard let chipName = Sysctl.string(for: "machdep.cpu.brand_string")?.lowercased() else { return nil }
        let knownAppleSiliconGPUCores: [String: Int] = [
            "m1 ultra": 64, "m1 max": 32, "m1 pro": 16, "m1": 8,
            "m2 ultra": 76, "m2 max": 38, "m2 pro": 19, "m2": 10,
            "m3 max": 40, "m3 pro": 18, "m3": 10,
            "m4 max": 40, "m4 pro": 20, "m4": 10
        ]
        return knownAppleSiliconGPUCores.first { chipName.contains($0.key) }?.value
    }
}

extension Double {
    var formattedTemperature: String {
        "\(Int(rounded())) °C"
    }
}

#endif
