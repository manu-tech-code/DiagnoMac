import Testing
@testable import DiagnoCore

@Suite struct SpeedTestParserTests {
    @Test func readsLiveProgress() {
        let line = SpeedTestParser.stripEscapes("\u{1B}[2KDownlink: 76.672 Mbps, 262 RPM - Uplink: 28.754 Mbps, 0 RPM")
        #expect(SpeedTestParser.progress(line) == SpeedTestReading(downloadMbps: 76.672, uploadMbps: 28.754, rpm: 262))
        #expect(SpeedTestParser.progress("==== SUMMARY ====") == nil)
    }

    @Test func readsTheSummary() {
        let lines = [
            "==== SUMMARY ====",
            "Uplink capacity: 21.188 Mbps",
            "Downlink capacity: 48.669 Mbps",
            "Uplink Responsiveness: Medium (258.605 milliseconds | 232 RPM)",
            "Downlink Responsiveness: Medium (237.730 milliseconds | 252 RPM)",
            "Idle Latency: 180.484 milliseconds | 332 RPM",
        ]
        let result = SpeedTestParser.summary(lines, fallback: nil)
        #expect(result == SpeedTestResult(downloadMbps: 48.669, uploadMbps: 21.188, responsivenessRPM: 252, idleLatencyMs: 180.484))
    }

    @Test func parallelSummaryUsesTheSingleResponsiveness() {
        let lines = ["Downlink capacity: 90.006 Mbps", "Uplink capacity: 17.040 Mbps", "Responsiveness: Low (215 RPM)"]
        #expect(SpeedTestParser.summary(lines, fallback: nil)?.responsivenessRPM == 215)
    }

    @Test func fallsBackToTheLastLiveReading() {
        let last = SpeedTestReading(downloadMbps: 80, uploadMbps: 20, rpm: 300)
        #expect(SpeedTestParser.summary(["networkQuality was interrupted"], fallback: last)
                == SpeedTestResult(downloadMbps: 80, uploadMbps: 20, responsivenessRPM: 300, idleLatencyMs: nil))
        #expect(SpeedTestParser.summary([], fallback: nil) == nil)
    }
}
