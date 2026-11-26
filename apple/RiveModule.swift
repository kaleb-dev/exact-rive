// exact-rive on iOS: `rive-view`, a Rive file's state machine, with the same props and messages as web/index.js.
// This file is the Exact side (props, the clock, pausing, events); Player.swift is the only file that touches
// RiveRuntime, so moving from RiveView to RiveUIView changes that file alone (README, "Roadmap").
//
// Time is Exact's: each frame advances the machine to the session clock's `now()` (the agent's virtual clock under
// the agent), in steps of at most 1/60 s, so `clock +1500` plays every transition and reports every trigger in order.
// Packages get no frame ticket, so under the agent frames come from `context.after(_:coalescing:)`, which runs on the
// virtual clock and never holds `clock settle`; on the live clock they come from a display link, for vsync.
// Rive's own display link never starts. Frames stop when the machine settles, the view is hidden or leaves its
// window, or the app goes to the background.
import ExactPackage
import Foundation
import UIKit

public final class RiveModule: ExactPackage {
    let context: ExactPackageContext
    private var views: [String: RiveViewInstance] = [:]
    private var hidden: Set<String> = []
    private(set) var foreground = true

    public init(context: ExactPackageContext) { self.context = context }

    public func later(_ name: String, _ args: [String: Any], preferred: Any?, reply: @escaping ([String: Any]) -> Void) {
        reply(["error": "NotSupportedError"])
    }

    public func view(_ tag: String, id: String, props: [String: String], events: ExactPackageEvents) throws -> ExactPackageView {
        guard tag == "rive-view" else { throw ExactPackageRefusal("no view \(tag)") }
        let v = RiveViewInstance(module: self, id: id, events: events)
        views[id] = v
        try v.setProps(props)
        return v
    }

    public func displayed(_ id: String, _ shown: Bool, origin: String) {
        if shown { hidden.remove(id) } else { hidden.insert(id) }
        views[id]?.wake()
    }

    public func foreground(_ shown: Bool) {
        foreground = shown
        for v in views.values { v.wake() }
    }

    public func destroy(_ done: @escaping () -> Void) {
        for v in views.values { v.destroy() }
        views = [:]
        done()
    }

    func isHidden(_ id: String) -> Bool { hidden.contains(id) }
    func gone(_ id: String) { views[id] = nil; hidden.remove(id) }
}

final class RiveViewInstance: NSObject, ExactPackageView {
    private weak var module: RiveModule?
    private let id: String
    private let events: ExactPackageEvents
    private let player: Player
    private var props: [String: String] = [:]
    private var key = ""
    private var counts: [String: String] = [:]
    private var ticker: Ticker?
    private var last = 0.0
    private var drawn = false
    private var loading: URLSessionDataTask?

    init(module: RiveModule, id: String, events: ExactPackageEvents) {
        self.module = module; self.id = id; self.events = events
        player = Player()
        super.init()
        player.say = { [weak self] in self?.events.message($0) }
        player.moved = { [weak self] in self?.wake() }
        events.intrinsicSize(CGSize(width: 200, height: 200))
    }

    var view: ExactPackagePlatformView { player.view }

    func setProps(_ props: [String: String]) throws {
        self.props = props
        player.layout(fit: props["fitMode"] ?? "", alignment: props["alignment"] ?? "")
        let key = ["source", "artboard", "stateMachine", "viewModel", "instance"].map { props[$0] ?? "" }.joined(separator: "|")
        if key != self.key {
            self.key = key
            load()
        } else {
            apply()
        }
    }

    private func load() {
        sleep(); loading?.cancel(); loading = nil
        counts = [:]; drawn = false
        let source = props["source"] ?? "", key = self.key
        if let url = URL(string: source), url.scheme == "https" || url.scheme == "http" {
            loading = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard let self, self.key == key else { return }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if let data, (200..<300).contains(status) { self.loaded(data) }
                    else { self.events.message("error:\(source): \(error?.localizedDescription ?? "HTTP \(status)")") }
                }
            }
            loading?.resume()
            return
        }
        // ponytail: the bundle (or EXACT_ASSETS) path, as Exact's own resolver falls back to; an over-the-air asset
        // update isn't seen here because the resolver is package-scoped. Fine while .riv files ship in the binary.
        let root = ProcessInfo.processInfo.environment["EXACT_ASSETS"] ?? Bundle.main.bundlePath
        do { loaded(try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(source))) }
        catch { events.message("error:\(source): \(error.localizedDescription)") }
    }

    private func loaded(_ data: Data) {
        let p = props
        guard player.load(data, source: p["source"] ?? "", artboard: p["artboard"] ?? "", stateMachine: p["stateMachine"] ?? "",
                          viewModel: p["viewModel"] ?? "", instance: p["instance"] ?? "") else { return }
        apply()
        if let s = p["opening"], !s.isEmpty { player.fire(s) }
        // After the values: the first frame shows them, as on the web, where they are set before the first advance.
        player.attach()
        wake()
    }

    private func apply() {
        guard player.loaded else { return }
        for (name, value) in pairs(props["values"]) { player.set(name, value) }
        // A trigger fires when its count changes, never for the count the view mounts with.
        for (name, count) in pairs(props["fire"]) {
            if let was = counts[name], was != count { player.fire(name) }
            counts[name] = count
        }
        wake()
    }

    private var running: Bool {
        guard let module else { return false }
        return player.loaded && player.view.window != nil && module.foreground && !module.isHidden(id)
    }

    /// Draw now, then step on the session's frames until the machine settles or the view is hidden.
    func wake() {
        guard ticker == nil, running, let module else { return }
        last = module.context.now()
        ticker = Ticker(module.context) { [weak self] in self?.tick() }
        tick()
    }

    private func tick() {
        guard running, let module else { return sleep() }
        let now = module.context.now()
        var dt = max(0, (now - last) / 1000), more = true
        last = now
        repeat {
            let step = min(dt, 1.0 / 60)
            dt -= step
            more = player.step(step)
        } while dt > 0 && more
        player.draw()
        if !drawn { drawn = true; events.load() }
        if !more { sleep() }
    }

    private func sleep() { ticker?.stop(); ticker = nil }

    func destroy() {
        sleep(); loading?.cancel()
        player.unload()
        module?.gone(id)
    }

    private func pairs(_ text: String?) -> [(String, String)] {
        (text ?? "").split(separator: ";", omittingEmptySubsequences: true).compactMap { part in
            guard let at = part.firstIndex(of: "=") else { return nil }
            let decode = { (s: Substring) in s.removingPercentEncoding ?? String(s) }
            let name = decode(part[..<at]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, decode(part[part.index(after: at)...]))
        }
    }
}

/// A frame callback on the session's clock: under the agent, `context.after` at 60 Hz of virtual time (coalesced, so
/// a seek runs it once at its end and a looping animation never holds `clock settle`); otherwise the display's vsync.
final class Ticker {
    private var cancel: (() -> Void)?
    private var link: CADisplayLink?
    private let context: ExactPackageContext
    private let body: () -> Void

    init(_ context: ExactPackageContext, _ body: @escaping () -> Void) {
        self.context = context; self.body = body
        if context.agent { schedule() } else {
            link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.fire))
            link?.add(to: .main, forMode: .common)
        }
    }

    private func schedule() {
        cancel = context.after(1000.0 / 60, coalescing: true) { [weak self] in
            guard let self, self.cancel != nil else { return }
            self.schedule()
            self.body()
        }
    }

    func stop() { cancel?(); cancel = nil; link?.invalidate(); link = nil }

    /// The display link holds its target strongly; this holds the ticker weakly.
    private final class Proxy: NSObject {
        weak var ticker: Ticker?
        init(_ ticker: Ticker) { self.ticker = ticker }
        @objc func fire() { ticker?.body() }
    }
}
