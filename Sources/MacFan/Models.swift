import Foundation

struct TemperatureProbe: Identifiable, Hashable {
    let id: String
    let rawKey: String
    let displayName: String
    let group: SensorGroup
    let celsius: Double
    let average15s: Double
    let historicHigh: Double
}

enum SensorGroup: String, CaseIterable, Codable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "Memory"
    case battery = "Battery"
    case enclosure = "Enclosure"
    case unknown = "Other"
}

struct HardwareInfo: Equatable {
    var cpuName: String = "Detecting CPU…"
    var cpuCoreCount: Int = ProcessInfo.processInfo.processorCount
    var gpuCoreCount: Int? = nil
}

struct FanStatus: Identifiable, Equatable {
    let id: Int
    var name: String
    var currentRPM: Int
    var minimumRPM: Int
    var maximumRPM: Int
    var targetRPM: Int?
}

enum FanMode: String, CaseIterable, Codable, Identifiable {
    case automatic = "Auto"
    case customRPM = "Custom RPM"
    case fullBlast = "Full Blast"
    case curve = "Fan Curve"

    var id: String { rawValue }
}

enum SafeOverrideMode: String, CaseIterable, Codable, Identifiable {
    case fullBlast = "Full Blast"
    case automatic = "Auto"

    var id: String { rawValue }
}

enum CurveTemperatureSource: String, CaseIterable, Codable, Identifiable {
    case hottestCPUCore = "Hottest CPU Core"
    case averageCPUCore = "Average CPU Core"
    case averageGPU = "Average GPU"

    var id: String { rawValue }
}

struct FanCurvePoint: Codable, Hashable, Identifiable {
    var id = UUID()
    var temperatureCelsius: Double
    var rpm: Int
}

struct FanCurve: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var source: CurveTemperatureSource
    var points: [FanCurvePoint]
    var isTemplate: Bool

    func rpm(for temperature: Double, minimumRPM: Int, maximumRPM: Int) -> Int {
        let sorted = points.sorted { $0.temperatureCelsius < $1.temperatureCelsius }
        guard let first = sorted.first else { return minimumRPM }
        guard let last = sorted.last else { return minimumRPM }

        if temperature <= first.temperatureCelsius {
            return first.rpm.clamped(to: minimumRPM...maximumRPM)
        }

        if temperature >= last.temperatureCelsius {
            return last.rpm.clamped(to: minimumRPM...maximumRPM)
        }

        for index in 0..<(sorted.count - 1) {
            let lower = sorted[index]
            let upper = sorted[index + 1]
            if temperature >= lower.temperatureCelsius && temperature <= upper.temperatureCelsius {
                let span = upper.temperatureCelsius - lower.temperatureCelsius
                let progress = span == 0 ? 0 : (temperature - lower.temperatureCelsius) / span
                let rpm = Double(lower.rpm) + (Double(upper.rpm - lower.rpm) * progress)
                return Int(rpm.rounded()).clamped(to: minimumRPM...maximumRPM)
            }
        }

        return minimumRPM
    }

    static let templates: [FanCurve] = [
        FanCurve(
            name: "Quiet",
            source: .averageCPUCore,
            points: [
                FanCurvePoint(temperatureCelsius: 40, rpm: 1500),
                FanCurvePoint(temperatureCelsius: 60, rpm: 2100),
                FanCurvePoint(temperatureCelsius: 78, rpm: 3300),
                FanCurvePoint(temperatureCelsius: 88, rpm: 5200)
            ],
            isTemplate: true
        ),
        FanCurve(
            name: "Regular",
            source: .hottestCPUCore,
            points: [
                FanCurvePoint(temperatureCelsius: 38, rpm: 1700),
                FanCurvePoint(temperatureCelsius: 55, rpm: 2600),
                FanCurvePoint(temperatureCelsius: 72, rpm: 4200),
                FanCurvePoint(temperatureCelsius: 85, rpm: 6200)
            ],
            isTemplate: true
        ),
        FanCurve(
            name: "Aggressive",
            source: .hottestCPUCore,
            points: [
                FanCurvePoint(temperatureCelsius: 35, rpm: 2200),
                FanCurvePoint(temperatureCelsius: 50, rpm: 3500),
                FanCurvePoint(temperatureCelsius: 65, rpm: 5200),
                FanCurvePoint(temperatureCelsius: 78, rpm: 7200)
            ],
            isTemplate: true
        )
    ]
}

struct AppSettings: Codable, Equatable {
    var fanMode: FanMode = .automatic
    var customRPM: Int = 2500
    var safeSystemEnabled: Bool = true
    var safeTemperatureCelsius: Double = 90
    var safeOverrideMode: SafeOverrideMode = .fullBlast
    var selectedCurveID: UUID = FanCurve.templates[1].id
    var customCurves: [FanCurve] = []

    var availableCurves: [FanCurve] {
        FanCurve.templates + customCurves
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
