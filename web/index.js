// exact-rive on the web: `rive-view`, a Rive file's state machine on a canvas, with the same props and messages as
// apple/RiveModule.swift. Rive's official low-level web runtime, @rive-app/canvas-advanced (MIT), is vendored
// unchanged in ./rive/ (for apps that serve it themselves) and loads when the first view mounts, never at import.
//
// Time is Exact's: each frame advances the machine by the session clock's `now()` (the agent's virtual clock under
// the agent), in steps of at most 1/60 s, so a `clock +1500` plays every transition and reports every trigger in
// order. Frames come from Rive's requestAnimationFrame (it flushes the canvas renderer) and stop when the machine
// settles, the view is hidden (`displayed`), scrolls out of sight, or the tab hides.

const STRING = 'string', NUMBER = 'number', BOOLEAN = 'boolean', COLOR = 'color', ENUM = 'enumType', TRIGGER = 'trigger';
const STEP = 1 / 60;
// Rive's runtime is fetched from a URL only when the first view mounts. A bundled `import('./rive/…')` would be a
// chunk, and Exact's page preloads every chunk as it starts, so every page would download it. The default is the
// pinned npm release on jsDelivr; an app serves its own copy of ./rive/ (README, "Self-hosting the web runtime") by
// naming its JS file in app.json: "packages": {"exact-rive": {"web": {"runtime": "modules/rive/canvas_advanced.js"}}}.
// The wasm is read from beside the JS file.
const RUNTIME = 'https://cdn.jsdelivr.net/npm/@rive-app/canvas-advanced@2.55.1/canvas_advanced.mjs';
let runtime = null;

function rive(config) {
  const url = new URL(config.runtime || RUNTIME, document.baseURI).href;
  return runtime ??= import(/* @vite-ignore */ url)
    .then(({ default: init }) => init({ locateFile: () => new URL('rive.wasm', url).href }))
    .catch((e) => { runtime = null; throw new Error(`the Rive runtime (${url}) did not load: ${e?.message ?? e}`); });
}

const decode = (s) => { try { return decodeURIComponent(s); } catch { return s; } };
/** "name=value;…", each part percent-decoded, so a value may carry `;`, `=` or `%` as %3B, %3D, %25. */
export const pairs = (text) => (text ?? '').split(';').flatMap((part) => {
  const at = part.indexOf('=');
  const name = at > 0 ? decode(part.slice(0, at).trim()) : '';
  return name ? [[name, decode(part.slice(at + 1))]] : [];
});
/** `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa` as [a, r, g, b], else null. */
export function rgba(text) {
  let h = text.trim().replace(/^#/, '');
  if (h.length === 3 || h.length === 4) h = [...h].map((c) => c + c).join('');
  if (!/^([0-9a-f]{6}|[0-9a-f]{8})$/i.test(h)) return null;
  const n = (i) => parseInt(h.slice(i, i + 2), 16);
  return [h.length === 8 ? n(6) : 255, n(0), n(2), n(4)];
}

class RiveView {
  constructor({ implementation, element, props, events, view }) {
    Object.assign(this, { impl: implementation, events, id: view, shown: true });
    this.canvas = element.ownerDocument.createElement('canvas');
    this.canvas.style.cssText = 'width:100%;height:100%;display:block';
    element.append(this.canvas);
    this.seen = new IntersectionObserver(([e]) => { this.shown = e.isIntersecting; this.wake(); });
    this.seen.observe(element);
    this.onVisibility = () => this.wake();
    document.addEventListener('visibilitychange', this.onVisibility);
    implementation.views.set(view, this);
    this.setProps(props);
  }

  setProps(props) {
    this.props = props;
    const key = ['source', 'artboard', 'stateMachine', 'viewModel', 'instance'].map((k) => props[k] ?? '').join('|');
    if (key !== this.key) { this.key = key; this.load(key).catch((e) => this.say(`error:${props.source}: ${e?.message ?? e}`)); }
    else this.apply();
  }

  say(text) { this.events.message(text); }

  async load(key) {
    this.free();
    const { source = '', artboard = '', stateMachine = '', viewModel = '', instance = '' } = this.props;
    const r = await rive(this.impl.config);
    const bytes = await fetch(new URL(source, document.baseURI)).then((res) => { if (!res.ok) throw new Error(`HTTP ${res.status}`); return res.arrayBuffer(); });
    const f = await r.load(new Uint8Array(bytes));
    if (key !== this.key || this.gone) return f.unref();
    Object.assign(this, { r, f, counts: {}, warned: new Set(), labels: new Map(), label: '', drawn: false, types: {}, triggers: [], ours: new Set() });
    try {
      this.ab = artboard ? f.artboardByName(artboard) : f.defaultArtboard();
      if (!this.ab) throw new Error(`no artboard "${artboard}"`);
      const def = stateMachine ? this.ab.stateMachineByName(stateMachine) : this.ab.stateMachineByIndex(0);
      if (!def) throw new Error(`no state machine ${stateMachine ? `"${stateMachine}"` : 'on the artboard'}`);
      this.sm = new r.StateMachineInstance(def, this.ab);
    } catch (e) { this.free(); throw e; }
    const vm = viewModel ? f.viewModelByName(viewModel) : f.defaultArtboardViewModel(this.ab);
    if (viewModel && !vm) this.warn(`no view model "${viewModel}"`);
    if (vm) {
      // The file's default instance keeps the values its author gave it; a blank `vm.instance()` would zero them.
      let vmi = instance ? vm.instanceByName(instance) : null;
      if (instance && !vmi) this.warn(`no view-model instance "${instance}"; the default plays`);
      vmi ??= vm.defaultInstance() ?? vm.instance();
      // Bound to both the artboard and the machine: data-bound drawing reads one, transitions the other.
      this.ab.bindViewModelInstance(vmi);
      this.sm.bindViewModelInstance(vmi);
      this.vmi = vmi;
      this.types = Object.fromEntries(vm.getProperties().map((p) => [p.name, p.type]));
      this.triggers = Object.keys(this.types).filter((n) => this.types[n] === TRIGGER).map((n) => [n, vmi.trigger(n)]).filter(([, t]) => t);
    }
    this.sm.enableSemantics();
    this.renderer = r.makeRenderer(this.canvas);
    // Before the first advance, so the first frame already shows them.
    this.apply();
    if (this.props.opening) this.fire(this.props.opening);
  }

  /** Once per name per file, loudly: a renamed property must not leave the art silently stuck. */
  warn(why) {
    if (this.warned.has(why)) return;
    this.warned.add(why);
    const line = `${this.props.source}: ${why}; skipped`;
    console.error(`exact-rive: ${line}`);
    this.say(`warn:${line}`);
  }

  missing(name) { this.warn(this.vmi ? `no view-model property "${name}"` : `no view model, so no property "${name}"`); }

  fire(name) {
    const t = this.types[name] === TRIGGER ? this.vmi.trigger(name) : null;
    if (!t) return this.missing(name);
    t.trigger();
    this.ours.add(name); // the file's triggers are reported, never the app's own
  }

  apply() {
    if (!this.sm) return;
    const { vmi, types } = this;
    for (const [name, v] of pairs(this.props.values)) {
      const type = types[name];
      if (type === NUMBER && v.trim() !== '' && !Number.isNaN(Number(v))) vmi.number(name).value = Number(v);
      else if (type === BOOLEAN) vmi.boolean(name).value = v.trim() === 'true';
      else if (type === STRING) vmi.string(name).value = v;
      else if (type === ENUM) vmi.enum(name).value = v.trim();
      else if (type === COLOR && rgba(v)) vmi.color(name).argb(...rgba(v));
      else if (type) this.warn(`"${v}" is not a ${type === ENUM ? 'enum' : type} for "${name}"`);
      else this.missing(name);
    }
    // A trigger fires when its count changes, never for the count the view mounts with.
    for (const [name, count] of pairs(this.props.fire)) {
      if (name in this.counts && this.counts[name] !== count) this.fire(name);
      this.counts[name] = count;
    }
    this.wake();
  }

  running() { return this.sm && this.shown && !this.impl.hidden.has(this.id) && !document.hidden && !this.gone; }

  wake() {
    if (this.raf || !this.running()) return;
    this.last = this.impl.now();
    this.raf = this.r.requestAnimationFrame(() => this.tick());
  }

  tick() {
    this.raf = 0;
    if (!this.running()) return;
    const t = this.impl.now();
    let dt = Math.max(0, (t - this.last) / 1000), more = true;
    this.last = t;
    do {
      const step = Math.min(dt, STEP);
      dt -= step;
      more = this.sm.advanceAndApply(step);
      this.report();
    } while (dt > 0 && more);
    this.semantics();
    this.draw();
    if (!this.drawn) { this.drawn = true; this.events.load(); }
    if (more) this.raf = this.r.requestAnimationFrame(() => this.tick());
  }

  /** What the file said in the step: its view-model triggers, and its legacy Rive events. */
  report() {
    for (const [name, t] of this.triggers) {
      if (!t.hasChanged) continue;
      t.clearChanges();
      if (!this.ours.delete(name)) this.say(`trigger:${name}`);
    }
    this.ours.clear();
    for (let i = 0; i < this.sm.reportedEventCount(); i++) {
      const e = this.sm.reportedEventAt(i);
      if (!e) continue;
      const props = e.properties && Object.keys(e.properties).length ? ` ${JSON.stringify(e.properties)}` : '';
      this.say(`event:${e.name}${props}`);
    }
  }

  /** The file's semantics labels, in node order, as one line: what a screen reader says for the view. */
  semantics() {
    const diff = this.sm.drainSemanticsDiff();
    if (!diff) return;
    for (const id of diff.removed) this.labels.delete(id);
    for (const n of [...diff.added, ...diff.updatedSemantic]) if (n.label) this.labels.set(n.id, n.label); else this.labels.delete(n.id);
    const label = [...this.labels.entries()].sort(([a], [b]) => a - b).map(([, l]) => l).join(', ');
    if (label !== this.label) { this.label = label; this.say(`label:${label}`); }
  }

  draw() {
    const dpr = globalThis.devicePixelRatio || 1, c = this.canvas;
    const w = Math.round(c.clientWidth * dpr), h = Math.round(c.clientHeight * dpr);
    if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
    const { r, renderer } = this, { fitMode: fit = '', alignment = '' } = this.props;
    if (fit && !(fit in r.Fit)) this.warn(`no fit "${fit}"`);
    if (alignment && !(alignment in r.Alignment)) this.warn(`no alignment "${alignment}"`);
    renderer.clear();
    renderer.save();
    renderer.align(r.Fit[fit] ?? r.Fit.contain, r.Alignment[alignment] ?? r.Alignment.center, { minX: 0, minY: 0, maxX: w, maxY: h }, this.ab.bounds);
    this.ab.draw(renderer);
    renderer.restore();
  }

  free() {
    if (this.raf) this.r.cancelAnimationFrame(this.raf);
    this.raf = 0;
    this.sm?.delete(); this.vmi?.unref?.(); this.renderer?.delete(); this.f?.unref();
    this.sm = this.vmi = this.renderer = this.f = this.ab = null;
  }

  destroy() {
    this.gone = true;
    this.free();
    this.impl.views.delete(this.id);
    this.seen.disconnect();
    document.removeEventListener('visibilitychange', this.onVisibility);
    this.canvas.remove();
  }
}

export const roster = { 'rive-view': { view: RiveView } };

export function implementation({ now = () => performance.now(), config = {} }) {
  const views = new Map(), hidden = new Set();
  return {
    views, hidden, now, config,
    displayed(view, shown) {
      if (shown) hidden.delete(view); else hidden.add(view);
      views.get(view)?.wake();
    },
  };
}
