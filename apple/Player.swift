// The renderer seam: the only file that touches RiveRuntime. It plays one file's state machine in rive-ios's legacy
// `RiveView`, stepped by RiveModule.swift's clock (setModel with autoPlay false, so Rive's own display link never
// starts). Moving to `RiveUIView` replaces this file and nothing else; README, "Roadmap", says when.
//
// Data binding: the artboard's view model (or `viewModel`), its default instance (or `instance`), bound to both the
// artboard and the state machine. A name the view model lacks is skipped, loudly: a log line and `warn:…`, once per
// name. The file's own triggers come back as `trigger:<name>`, legacy Rive events as `event:<name> <JSON>`.
import Foundation
import RiveRuntime
import UIKit

final class Player {
    /// `trigger:`, `event:`, `warn:` and `error:` messages.
    var say: (String) -> Void = { _ in }
    /// The view joined or left a window.
    var moved: () -> Void = {}
    private let canvas = Canvas()
    /// Held here: RiveView keeps its model weakly, and the machine dies with it.
    private var model: RiveModel?
    /// Held here too: an instance nothing holds stops updating.
    private var instance: RiveDataBindingViewModel.Instance?
    private var types: [String: RiveDataBindingViewModel.Instance.Property.Data.DataType] = [:]
    /// Triggers the app fired since the last listener pass: the app's own, never reported back.
    private var ours: Set<String> = []
    private var warned: Set<String> = []
    private var source = ""

    init() {
        canvas.backgroundColor = .clear
        canvas.moved = { [weak self] in self?.moved() }
    }

    var view: UIView { canvas }
    var loaded: Bool { model?.stateMachine != nil }

    func layout(fit: String, alignment: String) {
        let fits: [String: RiveFit] = ["fill": .fill, "contain": .contain, "cover": .cover, "fitWidth": .fitWidth,
                                       "fitHeight": .fitHeight, "none": .noFit, "scaleDown": .scaleDown, "layout": .layout]
        let alignments: [String: RiveAlignment] = ["topLeft": .topLeft, "topCenter": .topCenter, "topRight": .topRight,
                                                   "centerLeft": .centerLeft, "center": .center, "centerRight": .centerRight,
                                                   "bottomLeft": .bottomLeft, "bottomCenter": .bottomCenter, "bottomRight": .bottomRight]
        if !fit.isEmpty, fits[fit] == nil { warn("no fit \"\(fit)\"") }
        if !alignment.isEmpty, alignments[alignment] == nil { warn("no alignment \"\(alignment)\"") }
        canvas.fit = fits[fit] ?? .contain
        canvas.alignment = alignments[alignment] ?? .center
        canvas.setNeedsDisplay()
    }

    /// Loads `data`; on failure says `error:…` and stays unloaded.
    func load(_ data: Data, source: String, artboard: String, stateMachine: String, viewModel: String, instance name: String) -> Bool {
        unload()
        self.source = source
        do {
            let model = RiveModel(riveFile: try RiveFile(data: data, loadCdn: false))
            if artboard.isEmpty { try model.setArtboard() } else { try model.setArtboard(artboard) }
            if stateMachine.isEmpty { try model.setStateMachine() } else { try model.setStateMachine(stateMachine) }
            let vm = viewModel.isEmpty ? model.riveFile.defaultViewModel(for: model.artboard) : model.riveFile.viewModelNamed(viewModel)
            if !viewModel.isEmpty, vm == nil { warn("no view model \"\(viewModel)\"") }
            if let vm {
                var instance = name.isEmpty ? nil : vm.createInstance(fromName: name)
                if !name.isEmpty, instance == nil { warn("no view-model instance \"\(name)\"; the default plays") }
                // The file's default instance keeps the values its author gave it; a blank `createInstance()` zeroes them.
                instance = instance ?? vm.createDefaultInstance() ?? vm.createInstance()
                if let instance {
                    model.artboard.bind(viewModelInstance: instance)
                    model.stateMachine?.bind(viewModelInstance: instance)
                    for p in vm.properties {
                        types[p.name] = p.type
                        guard p.type == .trigger else { continue }
                        let name = p.name
                        _ = instance.triggerProperty(fromPath: name)?.addListener { [weak self] in
                            guard let self else { return }
                            if self.ours.remove(name) == nil { self.say("trigger:\(name)") }
                        }
                    }
                    self.instance = instance
                }
            }
            self.model = model
            return true
        } catch {
            unload()
            say("error:\(source): \(error.localizedDescription)")
            return false
        }
    }

    /// Puts the loaded model in the view; setModel advances it once, so values set before it show in the first frame.
    func attach() {
        guard let model else { return }
        do { try canvas.setModel(model, autoPlay: false) } catch { say("error:\(source): \(error.localizedDescription)") }
    }

    func unload() {
        model = nil; instance = nil; types = [:]; ours = []; warned = []
    }

    func set(_ name: String, _ value: String) {
        guard let instance else { return missing(name) }
        let v = value.trimmingCharacters(in: .whitespaces)
        switch types[name] {
        case .number?: if let n = Float(v) { instance.numberProperty(fromPath: name)?.value = n } else { bad(name, value, "number") }
        case .boolean?: instance.booleanProperty(fromPath: name)?.value = v == "true"
        case .string?: instance.stringProperty(fromPath: name)?.value = value
        case .enum?: instance.enumProperty(fromPath: name)?.value = v
        case .color?: if let c = color(v) { instance.colorProperty(fromPath: name)?.value = c } else { bad(name, value, "color") }
        case nil: missing(name)
        default: bad(name, value, "settable value")
        }
    }

    func fire(_ name: String) {
        guard types[name] == .trigger, let t = instance?.triggerProperty(fromPath: name) else { return missing(name) }
        ours.insert(name)
        t.trigger()
    }

    /// One step of the machine; reports what the file said in it. False once it has settled.
    func step(_ seconds: Double) -> Bool {
        guard let sm = model?.stateMachine else { return false }
        let more = sm.advance(by: seconds)
        for i in 0..<sm.reportedEventCount() {
            let e = sm.reportedEvent(at: i), props = e.properties()
            let json = props.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: props)).flatMap { String(data: $0, encoding: .utf8) }
            say(json.map { "event:\(e.name()) \($0)" } ?? "event:\(e.name())")
        }
        instance?.updateListeners()
        ours = []
        return more
    }

    /// Draws what the machine last applied.
    func draw() { canvas.advance(delta: 0) }

    private func missing(_ name: String) {
        warn(instance == nil ? "no view model, so no property \"\(name)\"" : "no view-model property \"\(name)\"")
    }

    private func bad(_ name: String, _ value: String, _ kind: String) { warn("\"\(value)\" is not a \(kind) for \"\(name)\"") }

    private func warn(_ why: String) {
        guard warned.insert(why).inserted else { return }
        let line = "\(source): \(why); skipped"
        print("exact-rive: \(line)")
        say("warn:\(line)")
    }

    /// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
    private func color(_ text: String) -> UIColor? {
        var h = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if h.count == 3 || h.count == 4 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let n = h.count == 6 ? v << 8 | 0xff : v
        let c = { (shift: UInt64) in CGFloat((n >> shift) & 0xff) / 255 }
        return UIColor(red: c(24), green: c(16), blue: c(8), alpha: c(0))
    }
}

/// A RiveView that draws at the given fit and alignment, and says when it joins or leaves a window.
private final class Canvas: RiveView {
    var moved: (() -> Void)?
    var fit: RiveFit = .contain
    var alignment: RiveAlignment = .center
    /// Set by setModel; RiveView doesn't expose the artboard it draws.
    weak var artboard: RiveArtboard?

    override func didMoveToWindow() { super.didMoveToWindow(); moved?() }

    override func setModel(_ model: RiveModel, autoPlay: Bool = true) throws {
        artboard = model.artboard
        try super.setModel(model, autoPlay: autoPlay)
    }

    override func drawRive(_ rect: CGRect, size: CGSize) {
        guard let artboard else { return }
        align(with: CGRect(origin: rect.origin, size: size), contentRect: artboard.bounds(), alignment: alignment, fit: fit,
              scaleFactor: fit == .layout ? window?.screen.scale ?? 1 : 1)
        draw(with: artboard)
    }
}
