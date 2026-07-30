import Foundation

/// DEBUG launch flags that compile OUT of Release — a shipping binary carries no demo, marketing,
/// or UI-test switches (production-readiness sweep 2026-07-16). Use this instead of checking
/// `ProcessInfo.processInfo.arguments` directly anywhere a flag gates behavior; the Release build
/// then provably cannot enter those paths.
@inlinable
func debugFlag(_ argument: String) -> Bool {
    #if DEBUG
    return ProcessInfo.processInfo.arguments.contains(argument)
    #else
    return false
    #endif
}
