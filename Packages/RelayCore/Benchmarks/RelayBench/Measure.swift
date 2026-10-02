import Foundation

/// Timing and statistics.
///
/// Durations come from `ContinuousClock`, which is monotonic: it never jumps with
/// wall-clock adjustments.
@MainActor
enum Measure {
    static let clock = ContinuousClock()

    static func nanoseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1e9 + Double(attoseconds) / 1e9
    }

    /// Times one async operation.
    static func time<T>(_ body: () async throws -> T) async rethrows -> (result: T, ns: Double) {
        let start = clock.now
        let result = try await body()
        return (result, nanoseconds(start.duration(to: clock.now)))
    }
}

/// Summary of a sample of durations.
///
/// **Percentiles use the nearest-rank method:** the p-th percentile of n sorted samples
/// is the sample at 1-based rank ⌈p/100 × n⌉. It is always an observed value, with no
/// interpolation. With n = 2,000, p99 is the 1,980th fastest sample, so 20 samples lie
/// above it.
struct Summary: Codable {
    let count: Int
    let minMs: Double
    let medianMs: Double
    let p95Ms: Double
    let p99Ms: Double
    let maxMs: Double
    let meanMs: Double

    init(nanoseconds samples: [Double]) {
        precondition(!samples.isEmpty)
        let sorted = samples.sorted()
        func rank(_ p: Double) -> Double {
            let index = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
            return sorted[min(max(index, 0), sorted.count - 1)] / 1e6
        }
        count = sorted.count
        minMs = sorted.first! / 1e6
        medianMs = rank(50)
        p95Ms = rank(95)
        p99Ms = rank(99)
        maxMs = sorted.last! / 1e6
        meanMs = sorted.reduce(0, +) / Double(sorted.count) / 1e6
    }
}

/// One workload configuration's results: every independent repetition, plus all
/// samples pooled.
struct WorkloadResult: Codable {
    let workload: String
    let variant: String
    let notesInDatabase: Int
    let operationsPerRepetition: Int
    let commitMode: String
    let repetitions: [Summary]
    let pooled: Summary
    /// Extra derived numbers, for example changes per second.
    let derived: [String: Double]
    /// What was checked after the timed work, outside the timed region.
    let validation: String
    let rawSamplesNs: [[Double]]?
}

/// Keeps a value observable, so the optimizer can't discard the work producing it.
@inline(never)
func blackHole<T>(_ value: T) {
    withExtendedLifetime(value) {}
}

struct BenchmarkFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw BenchmarkFailure("Validation failed: \(message())") }
}
