import Testing

/// Every suite that touches process-wide state (the shared instance, `Environment`, the stub server)
/// nests here: `.serialized` is inherited, so they never run alongside each other. Pure suites stay
/// top level and parallel.
///
/// `.webKitWarmedUp` loads one frame page before the first of them runs: the process's first page pays for
/// launching WebKit, which on a cold CI runner took tens of seconds, and it no longer lands inside whichever
/// test happens to load a page first, against that test's limits.
@Suite(.serialized, .webKitWarmedUp)
enum SerialSuites {}

/// Runs `WebKitWarmup.ensure()` once, before the suite it is attached to.
struct WebKitWarmedUp: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        await WebKitWarmup.ensure()
        try await function()
    }
}

extension Trait where Self == WebKitWarmedUp {
    static var webKitWarmedUp: Self { Self() }
}
