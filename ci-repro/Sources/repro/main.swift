import Foundation
import Lib

// Usage: repro <variant> <handed|timeout>
let args = CommandLine.arguments
let variant = args[1]
let mode = args[2]

func run<L>(_ l: L, acquire: @escaping @Sendable (L) async -> Bool, release: (L) -> Void, take: (L) async -> Void, waiting: (L) -> Int) async where L: Sendable {
    await take(l)
    let w = Task { await acquire(l) }
    while waiting(l) == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
    if mode == "handed" { release(l) }
    let got = await w.value
    if got { release(l) }
    if mode == "timeout" { release(l) }
    try? await Task.sleep(nanoseconds: 50_000_000)
}

let t: TimeInterval = mode == "handed" ? 30 : 0.05
for _ in 0..<20 {
    switch variant {
    case "methodRef": // as the app: Api.sleep, the default argument
        let s = Api().sleep
        await run(AsyncLock(), acquire: { await $0.acquire(within: t, sleep: s) }, release: { $0.release() }, take: { await $0.acquire() }, waiting: { $0.waiting })
    case "literal":
        let s: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
        await run(AsyncLock(), acquire: { await $0.acquire(within: t, sleep: s) }, release: { $0.release() }, take: { await $0.acquire() }, waiting: { $0.waiting })
    case "staticLet":
        let s = Api.sleepLet
        await run(AsyncLock(), acquire: { await $0.acquire(within: t, sleep: s) }, release: { $0.release() }, take: { await $0.acquire() }, waiting: { $0.waiting })
    case "doCatch":
        let s = Api().sleep
        await run(AsyncLockDoCatch(), acquire: { await $0.acquire(within: t, sleep: s) }, release: { $0.release() }, take: { await $0.acquire() }, waiting: { $0.waiting })
    case "wrapped": // Api.sleep wrapped in a closure literal at the call site
        let s0 = Api().sleep
        let s: @Sendable (TimeInterval) async throws -> Void = { try await s0($0) }
        await run(AsyncLock(), acquire: { await $0.acquire(within: t, sleep: s) }, release: { $0.release() }, take: { await $0.acquire() }, waiting: { $0.waiting })
    default: fatalError("variant")
    }
}
print("ok \(variant) \(mode)")
