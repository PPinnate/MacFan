#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

@main
struct MacFanApp: App {
    @StateObject private var store = SensorStore()

    var body: some Scene {
        MenuBarExtra {
            MacFanMenuView()
                .environmentObject(store)
                .frame(width: 440)
        } label: {
            Label(statusTitle, systemImage: store.safetyOverrideActive ? "flame.fill" : "fanblades.fill")
                .symbolRenderingMode(store.safetyOverrideActive ? .multicolor : .hierarchical)
        }
        .menuBarExtraStyle(.window)
    }

    private var statusTitle: String {
        if let hottest = store.hottestTemperature {
            return "MacFan \(hottest.formattedTemperature)"
        }
        return "MacFan"
    }
}

struct MacFanMenuView: View {
    @EnvironmentObject private var store: SensorStore
    @State private var newCurveName = ""

    var body: some View {
        VStack(spacing: 16) {
            header
            Divider()
            hardwareCard
            fanControlCard
            safetyCard
            curveCard
            sensorCard
            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Image(systemName: "fanblades.fill")
                    .foregroundStyle(.white)
                    .font(.title2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("MacFan")
                    .font(.title2.weight(.bold))
                Text(store.lastControlMessage)
                    .font(.caption)
                    .foregroundStyle(store.safetyOverrideActive ? .red : .secondary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered)
        }
    }

    private var hardwareCard: some View {
        CardView(title: "Hardware", systemImage: "cpu") {
            InfoRow(label: "CPU", value: store.hardware.cpuName)
            InfoRow(label: "CPU Cores", value: "\(store.hardware.cpuCoreCount)")
            InfoRow(label: "GPU Cores", value: store.hardware.gpuCoreCount.map(String.init) ?? "Unknown")
        }
    }

    private var fanControlCard: some View {
        CardView(title: "Fan Control", systemImage: "slider.horizontal.3") {
            Picker("Mode", selection: $store.settings.fanMode) {
                ForEach(FanMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if store.settings.fanMode == .customRPM {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Custom RPM")
                        Spacer()
                        Text("\(store.settings.customRPM)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(store.settings.customRPM) },
                            set: { store.settings.customRPM = Int($0.rounded()) }
                        ),
                        in: Double(globalMinimumRPM)...Double(globalMaximumRPM),
                        step: 50
                    )
                }
            }

            ForEach(store.fans) { fan in
                HStack {
                    Text(fan.name)
                    Spacer()
                    Text("\(fan.currentRPM) RPM")
                        .monospacedDigit()
                    Text("\(fan.minimumRPM)-\(fan.maximumRPM)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var safetyCard: some View {
        CardView(title: "Temperature-Safe System", systemImage: "shield.lefthalf.filled") {
            Toggle("Enabled", isOn: $store.settings.safeSystemEnabled)
            HStack {
                Text("Threshold")
                Spacer()
                Stepper("\(Int(store.settings.safeTemperatureCelsius)) °C", value: $store.settings.safeTemperatureCelsius, in: 70...105, step: 1)
                    .labelsHidden()
            }
            Picker("Override", selection: $store.settings.safeOverrideMode) {
                ForEach(SafeOverrideMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("When the hottest probe reaches the threshold, MacFan ignores custom RPM and curve choices to protect the Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var curveCard: some View {
        CardView(title: "Fan Curve", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
            Picker("Curve", selection: $store.settings.selectedCurveID) {
                ForEach(store.settings.availableCurves) { curve in
                    Text(curve.name).tag(curve.id)
                }
            }

            Picker("Temperature Source", selection: selectedCurveSourceBinding) {
                ForEach(CurveTemperatureSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }

            CurvePreview(curve: store.selectedCurve, minRPM: globalMinimumRPM, maxRPM: globalMaximumRPM)
                .frame(height: 92)

            HStack {
                TextField("Custom curve name", text: $newCurveName)
                    .textFieldStyle(.roundedBorder)
                Button("Save Copy") {
                    store.addCustomCurve(named: newCurveName)
                    newCurveName = ""
                }
                .buttonStyle(.borderedProminent)
            }

            if !store.selectedCurve.isTemplate {
                Button(role: .destructive) {
                    store.deleteCustomCurve(store.selectedCurve)
                } label: {
                    Label("Delete Custom Curve", systemImage: "trash")
                }
            }
        }
    }

    private var sensorCard: some View {
        CardView(title: "Temperatures", systemImage: "thermometer.medium") {
            if store.probes.isEmpty {
                Text("No temperature probes are visible yet. On some Macs, SMC access requires elevated permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    GridRow {
                        Text("Probe").font(.caption.weight(.semibold))
                        Text("Now").font(.caption.weight(.semibold))
                        Text("Avg 15s").font(.caption.weight(.semibold))
                        Text("High").font(.caption.weight(.semibold))
                    }
                    Divider().gridCellColumns(4)
                    ForEach(store.probes.prefix(14)) { probe in
                        GridRow {
                            Text(probe.displayName)
                                .lineLimit(1)
                            Text(probe.celsius.formattedTemperature)
                                .monospacedDigit()
                            Text(probe.average15s.formattedTemperature)
                                .monospacedDigit()
                            Text(probe.historicHigh.formattedTemperature)
                                .monospacedDigit()
                                .foregroundStyle(probe.historicHigh >= store.settings.safeTemperatureCelsius ? .red : .secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh") { store.refresh() }
            Spacer()
            Text("Standalone SMC backend • no mactop dependency")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedCurveSourceBinding: Binding<CurveTemperatureSource> {
        Binding {
            store.selectedCurve.source
        } set: { source in
            var curve = store.selectedCurve
            curve.source = source
            if curve.isTemplate {
                curve.id = UUID()
                curve.name = "\(curve.name) Custom"
                curve.isTemplate = false
                curve.source = source
                store.settings.customCurves.append(curve)
                store.settings.selectedCurveID = curve.id
            } else {
                store.updateSelectedCurve(curve)
            }
        }
    }

    private var globalMinimumRPM: Int {
        store.fans.map(\.minimumRPM).min() ?? 1200
    }

    private var globalMaximumRPM: Int {
        store.fans.map(\.maximumRPM).max() ?? 7200
    }
}

struct CardView<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.caption)
    }
}

struct CurvePreview: View {
    let curve: FanCurve
    let minRPM: Int
    let maxRPM: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [.blue.opacity(0.18), .red.opacity(0.18)], startPoint: .leading, endPoint: .trailing))
                Path { path in
                    let points = normalizedPoints(in: geometry.size)
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        .overlay(alignment: .topLeading) {
            Text("\(curve.name) • \(curve.source.rawValue)")
                .font(.caption2.weight(.semibold))
                .padding(8)
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        let sorted = curve.points.sorted { $0.temperatureCelsius < $1.temperatureCelsius }
        guard let minTemp = sorted.map(\.temperatureCelsius).min(),
              let maxTemp = sorted.map(\.temperatureCelsius).max(),
              maxTemp > minTemp,
              maxRPM > minRPM else { return [] }
        return sorted.map { point in
            let x = (point.temperatureCelsius - minTemp) / (maxTemp - minTemp) * size.width
            let yRatio = Double(point.rpm - minRPM) / Double(maxRPM - minRPM)
            let y = size.height - (yRatio.clamped(to: 0...1) * size.height)
            return CGPoint(x: x, y: y)
        }
    }
}

#else

@main
struct MacFanCLIStub {
    static func main() {
        print("MacFan is a macOS Menu Bar app. Build and run it on macOS 13 or newer.")
    }
}

#endif
