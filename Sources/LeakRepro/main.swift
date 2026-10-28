import Foundation
import JavaScriptCore
import JavaScriptCoreExtras

/// Evaluates `script` in a fresh JSContext, waits for the Promise it returns to settle, releases
/// the context, and returns whether the context was then deallocated.
func contextIsFreed(script: String, install: (JSContext) throws -> Void) rethrows -> Bool {
  weak var weakContext: JSContext?
  var settled = false
  try autoreleasepool {
    let context = JSContext()!
    weakContext = context
    try install(context)
    let done: @convention(block) () -> Void = { settled = true }
    context.setObject(done, forKeyedSubscript: "done" as NSString)
    context.evaluateScript("(\(script)).then(done, done)")
  }
  spinRunLoop { settled }
  precondition(settled, "the Promise never settled")
  spinRunLoop { weakContext == nil }
  return weakContext == nil
}

func spinRunLoop(until condition: () -> Bool) {
  let deadline = Date(timeIntervalSinceNow: 2)
  while !condition() && Date() < deadline {
    autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
  }
}

func report(_ name: String, _ isFreed: Bool) {
  print("\(isFreed ? "freed " : "LEAKED") \(name)")
}

// Control: a plain JS Promise, without JavaScriptCoreExtras.
report(
  "plain JS Promise",
  contextIsFreed(script: "Promise.resolve(1)") { _ in }
)

// Leak 1: JSPromise. Lock/RecursiveLock deinit deallocates their storage without deinitializing
// it, so JSPromise.Continuation's promise/resolve/reject JSValues are never released, and each
// one retains its JSContext.
report(
  "JSPromise",
  contextIsFreed(script: "makePromise()") { context in
    let makePromise: @convention(block) () -> JSValue = {
      JSPromise(in: .current()) { continuation in continuation.resume(resolving: 1) }.value
    }
    context.setObject(makePromise, forKeyedSubscript: "makePromise" as NSString)
  }
)

// Leak 2: fetch(). Every fetch() goes through JSPromise, so it hits Leak 1. Separately, even with
// Leak 1 fixed, JSURLSessionDataDelegate never removes a task's state, which holds its
// continuation, after the task completes. This happens with both the shared delegate used by
// .fetch / .fetch(sessionConfiguration:) and the per-task delegate used by .fetch(session:).
report(
  "fetch() with .fetch(sessionConfiguration:) (shared delegate)",
  try contextIsFreed(script: "fetch('https://example.com').then((r) => r.text())") {
    try $0.install([.fetch(sessionConfiguration: .stubbed)])
  }
)
report(
  "fetch() with .fetch(session:) (per-task delegate)",
  try contextIsFreed(script: "fetch('https://example.com').then((r) => r.text())") {
    try $0.install([.fetch(session: URLSession(configuration: .stubbed))])
  }
)

/// Answers every request with "hello", so the repro doesn't need the network.
final class StubURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("hello".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

extension URLSessionConfiguration {
  static var stubbed: URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return configuration
  }
}
