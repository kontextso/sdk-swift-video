import Testing

/// Every suite that touches process-wide state (the shared instance, `Environment`, the stub server)
/// nests here: `.serialized` is inherited, so they never run alongside each other. Pure suites stay
/// top level and parallel.
@Suite(.serialized)
enum SerialSuites {}
