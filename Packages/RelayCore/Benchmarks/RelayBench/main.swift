import Foundation
import RelayCore

// RelayBench: local performance measurements of Relay's storage and sync-application
// code. See BENCHMARKS.md for the methodology. Run with Scripts/benchmark.sh.
//
// Usage: RelayBench [--quick] [--output DIR] [--only WORKLOAD[,WORKLOAD…]]
// Workloads: save, reopen, search, incoming, recovery

struct Environment: Codable {
    let date: String
    let buildConfiguration: String
    let machineModel: String
    let cpu: String
    let cpuCores: Int
    let performanceCores: Int
    let memoryGB: Double
    let macOS: String
    let swift: String
    let xcode: String
    let gitRevision: String
    let gitDirtyFiles: String
    let power: String
    let lowPowerMode: Bool
    let thermalStateAtStart: String
    var thermalStateAtEnd: String
    let durability: String
    let seed: String
    let quick: Bool

    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func sysctlInt(_ name: String) -> Int64 {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return value
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

let arguments = CommandLine.arguments.dropFirst()
let quick = arguments.contains("--quick")
var config = quick ? Configuration.quick : Configuration()
func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
    return arguments[arguments.index(after: index)]
}
let outputDirectory = URL(fileURLWithPath: argument(after: "--output") ?? "benchmark-results", isDirectory: true)
let only = Set((argument(after: "--only") ?? "save,reopen,search,incoming,recovery").split(separator: ",").map(String.init))

#if DEBUG
let buildConfiguration = "debug"
FileHandle.standardError.write(Data("warning: debug build; numbers are not representative. Use -c release.\n".utf8))
#else
let buildConfiguration = "release"
#endif

let env = ProcessInfo.processInfo.environment
let startDate = Date()
var environment = Environment(
    date: ISO8601DateFormatter().string(from: startDate),
    buildConfiguration: buildConfiguration,
    machineModel: Environment.sysctl("hw.model"),
    cpu: Environment.sysctl("machdep.cpu.brand_string"),
    cpuCores: Int(Environment.sysctlInt("hw.ncpu")),
    performanceCores: Int(Environment.sysctlInt("hw.perflevel0.physicalcpu")),
    memoryGB: Double(Environment.sysctlInt("hw.memsize")) / 1_073_741_824,
    macOS: ProcessInfo.processInfo.operatingSystemVersionString,
    swift: env["RELAY_BENCH_SWIFT"] ?? "unknown (run via Scripts/benchmark.sh)",
    xcode: env["RELAY_BENCH_XCODE"] ?? "unknown",
    gitRevision: env["RELAY_BENCH_GIT_REVISION"] ?? "unknown",
    gitDirtyFiles: env["RELAY_BENCH_GIT_DIRTY"] ?? "unknown",
    power: env["RELAY_BENCH_POWER"] ?? "unknown",
    lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
    thermalStateAtStart: Environment.thermal(),
    thermalStateAtEnd: "",
    durability: "NoteStore's own settings: journal_mode=WAL, synchronous=FULL, fullfsync=ON, checkpoint_fullfsync=ON",
    seed: String(config.seed, radix: 16),
    quick: quick
)

func log(_ message: String) {
    FileHandle.standardError.write(Data("[\(String(format: "%6.1f", Date().timeIntervalSince(startDate)))s] \(message)\n".utf8))
}

let workspace = try Workspace()
log("Workspace: \(workspace.root.path)")
var results: [WorkloadResult] = []

do {
    let workloads = Workloads(config: config, workspace: workspace)
    for size in config.sizes {
        log("Building \(size)-note template (setup, untimed)…")
        _ = try await workspace.template(for: workloads.dataset(size), created: workloads.created)
    }
    for size in config.sizes {
        if only.contains("save") {
            log("save-latency, \(size) notes")
            results.append(try await workloads.saveLatency(size: size))
        }
        if only.contains("reopen") {
            log("reopened-store, \(size) notes")
            results += try await workloads.reopen(size: size)
        }
        if only.contains("search") {
            log("search, \(size) notes")
            results += try await workloads.search(size: size)
        }
        if only.contains("incoming") {
            log("incoming-changes, \(size) notes")
            results.append(try await workloads.incoming(size: size))
        }
        if only.contains("recovery") {
            log("pending-recovery, \(size) notes")
            results.append(try await workloads.recovery(size: size))
        }
    }
} catch {
    workspace.removeAll()
    log("FAILED: \(error)")
    exit(1)
}
workspace.removeAll()
environment.thermalStateAtEnd = Environment.thermal()

// MARK: Output

struct Report: Codable {
    let environment: Environment
    let results: [WorkloadResult]
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let stamp = ISO8601DateFormatter().string(from: startDate).replacingOccurrences(of: ":", with: "")
let name = "relaybench-\(stamp)-\(environment.gitRevision)\(quick ? "-quick" : "").json"
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let outputURL = outputDirectory.appending(path: name)
try encoder.encode(Report(environment: environment, results: results)).write(to: outputURL)

func ms(_ value: Double) -> String { String(format: value < 1 ? "%.3f" : "%.2f", value) }

print("""
    ## RelayBench results (\(environment.date))

    \(environment.machineModel), \(environment.cpu), \(Int(environment.memoryGB)) GB, \(environment.macOS)
    Build: \(environment.buildConfiguration). Git: \(environment.gitRevision) (dirty files: \(environment.gitDirtyFiles)). Power: \(environment.power), Low Power Mode \(environment.lowPowerMode ? "ON" : "off"). Thermal: \(environment.thermalStateAtStart) → \(environment.thermalStateAtEnd).

    | Workload | Variant | Notes | Ops/rep × reps | Median ms | p95 ms | p99 ms | Max ms | Per-rep medians (ms) |
    |---|---|---:|---:|---:|---:|---:|---:|---|
    """)
for result in results {
    let medians = result.repetitions.map { ms($0.medianMs) }.joined(separator: ", ")
    print("| \(result.workload) | \(result.variant) | \(result.notesInDatabase) | \(result.operationsPerRepetition) × \(result.repetitions.count) | \(ms(result.pooled.medianMs)) | \(ms(result.pooled.p95Ms)) | \(ms(result.pooled.p99Ms)) | \(ms(result.pooled.maxMs)) | \(medians) |")
}
for result in results where !result.derived.isEmpty {
    let derived = result.derived.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.0f", $0.value))" }.joined(separator: ", ")
    print("\n\(result.workload) / \(result.variant) / \(result.notesInDatabase) notes: \(derived)")
}
print("\nRaw results: \(outputURL.path)")
