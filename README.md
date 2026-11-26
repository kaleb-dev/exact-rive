# exact-rive

[Rive](https://rive.app) for [Exact](https://github.com/expo/exact) apps. One native view, `rive-view`, plays a
`.riv` file's state machine on iOS and the web. Contract drives it through the file's view model (data binding) and
hears what the file says back. A thin Contract component, `Rive`, adds the still fallback and reduced motion.

- **iOS:** Rive's official runtime, [rive-ios](https://github.com/rive-app/rive-ios) 6.31.0, through Swift Package
  Manager.
- **Web:** Rive's official low-level runtime,
  [@rive-app/canvas-advanced](https://www.npmjs.com/package/@rive-app/canvas-advanced) 2.55.1. It loads lazily,
  the first time a view mounts.
- **Android:** not implemented yet. The view reports an error, so `Rive` shows its still.

The Rive runtime docs are at <https://rive.app/docs/runtimes/getting-started>. Data binding, which this package is
built on, is described at <https://rive.app/docs/runtimes/data-binding>.

## Install

npm publishing comes later. Until then, install from GitHub or from a path.

```sh
# From GitHub (a private repository needs your GitHub credentials in git)
bun add github:kaleb-dev/exact-rive

# From a checkout beside your app: link it, so the package isn't copied
(cd ../exact-rive && bun link) && bun add link:exact-rive

# From npm, once it is published
bun add exact-rive
```

The app must list `exact-rive` in its own `dependencies`; Exact links a package's native code only for a direct
dependency. Then, for iOS, lock the Swift package and commit the lock:

```sh
bun exact.mjs lock   # writes Package.resolved with rive-ios 6.31.0
```

No `app.json` entry is needed. The package declares its view, and Exact builds its Swift and bundles its web code.

## Usage

```text
use Rive from "exact-rive/contract"

component Hero
  state cheers = 0
  action cheer
    cheers = cheers + 1
  action heard(m: string)
    if m == "trigger:cheerDone"
      ...
  view
    column width=240 height=240
      Rive(source="assets/hero.riv", artboard="", stateMachine="", viewModel="", instance="", fit="contain", alignment="center", values="mood=happy;size=2", fire=`cheer=${cheers}`, opening="", label="Our hero, waving", still="assets/hero.png", reducedMotion="still", heard=heard)
```

`Rive` fills its parent's box, so size the parent. Contract props have no defaults, so every prop is passed. Most
apps wrap `Rive` once in a component of their own that names their file's properties. Etudio's mascot, for
example, takes `mode`, `talking` and `right` and builds the `values` and `fire` strings itself.

### `Rive` props

| Prop | What it is |
|---|---|
| `source` | An `assets/` path or an `https:` URL of a `.riv` file. |
| `artboard` | The artboard's name; `""` for the file's default. |
| `stateMachine` | The state machine's name; `""` for the artboard's first. |
| `viewModel` | The view model's name; `""` for the artboard's own. A file with none still plays. |
| `instance` | The view-model instance's name; `""` for the default instance, which keeps the values the file's author gave it. |
| `fit` | `contain` (`""`), `cover`, `fill`, `fitWidth`, `fitHeight`, `none`, `scaleDown` or `layout`. |
| `alignment` | `center` (`""`), `topLeft`, `topCenter`, `topRight`, `centerLeft`, `centerRight`, `bottomLeft`, `bottomCenter` or `bottomRight`. |
| `values` | `"name=value;…"`: the view model's number, boolean (`true`/`false`), string, colour (`#rgb`, `#rrggbb`, `#rrggbbaa`) and enum (the value's key) properties. Each name and value is percent-decoded, so write `;`, `=` and `%` inside a value as `%3B`, `%3D`, `%25`; `encodeURIComponent(text)` does this in Contract. |
| `fire` | `"name=count;…"`: a trigger property fires each time its count changes. The count the view mounts with fires nothing. Keep a count in state and add 1 at the moment. |
| `opening` | A trigger to fire once, at the first frame (a hello's wave), else `""`. |
| `label` | What a screen reader says for the view. On the web, the file's own semantics label wins when it has one. |
| `still` | An image shown instead of the animation, else `""`. The component's children show there too, so an app can pass its own drawing. |
| `reducedMotion` | `"still"` (or `""`): under the system's reduced motion the still shows and the native view is never made, so no Rive runtime loads. `"play"` plays the file anyway (for a file with its own reduced-motion design). |
| `heard` | An action that takes every message (below). |

The still also shows until Rive's first frame, and when the file can't load. While Rive loads, the still is hidden
from screen readers, so the two never read twice.

### Messages

Every message is a string with a prefix, so a name can't be misread:

| Message | When |
|---|---|
| `trigger:<name>` | The file fired a view-model trigger of its own (a reaction finished). Triggers the app fired are not echoed back. |
| `event:<name> <JSON>` | The file reported a legacy Rive event; the JSON holds its custom properties, when it has any. |
| `label:<text>` | The file's semantics labels changed (web only; see Limitations). |
| `warn:<why>` | A name the file lacks: a property, view model, instance, fit or alignment. It is skipped, logged loudly, and said once per name per file. |
| `error:<why>` | The file, its artboard or its state machine can't load. `Rive` then shows the still. |

### The `rive-view` tag

`Rive` is a thin wrapper. An app can place the tag itself:
`rive-view source=… artboard=… stateMachine=… viewModel=… instance=… fitMode=… alignment=… values=… fire=… opening=… load=… message=…`.
Every prop but `source` is optional. The fit prop is `fitMode` on the tag, because `fit` is a name Contract
already gives the box. `load` runs at the first drawn frame. `message` takes the messages above.

## How it plays

- **Data binding.** The view binds one view-model instance to both the artboard and the state machine. Data-bound
  drawing reads the artboard's binding; transitions read the machine's. Values are set before the first frame, so
  that frame already shows them.
- **Exact's clock.** Each frame advances the machine to the session clock's time, in steps of at most 1/60 s. Under
  Exact's agent that clock is virtual, so `clock +1500` in a test plays every transition and reports every trigger,
  the same way on every run. Rive's own display link never starts. On iOS, frames come from `context.after` on the
  agent's clock (packages get no frame ticket; coalesced, so a looping animation never holds `clock settle`) and
  from a display link on the live clock. On the web they come from Rive's `requestAnimationFrame`.
- **Pausing.** Frames stop when the machine settles, the view is hidden (Exact's `displayed`), it leaves its window
  (iOS), it scrolls out of sight or the tab hides (web), or the app goes to the background. Time spent hidden is
  skipped, not played on return.
- **Holding the model.** On iOS, `RiveView` holds its model weakly, which crashed the first prototype; the package
  holds the model and the view-model instance itself.

## Limitations

- **iOS uses rive-ios's legacy `RiveView`.** `RiveView` and its data-binding API are marked deprecated in
  RiveRuntime 6.31, in favour of the newer concurrency runtime and its `RiveUIView`. They still work. The package
  stays on `RiveView` because Exact's clock can step it, which makes tests repeatable. `RiveUIView` runs its own
  display link, and Exact can't step that yet.
- **On iOS, VoiceOver reads `label`, not the file's own semantics.** `RiveView` has no accessibility semantics. Pass
  the words the file's label would say, and iOS and the web read the same.
- **The web runtime is the single-file build**, with its wasm inlined: about 3.4 MB (about 1.3 MB gzipped), against
  2.5 MB (1.03 MB) for the JS and wasm as two files. Exact bundles a package's web code but serves no file beside
  it for a views-only package. It is fetched only when a view mounts, never under reduced motion.
- **iOS pauses when hidden or out of its window,** but keeps drawing while scrolled out of sight inside a visible
  scroller, if Exact still reports the view displayed.
- **Android** isn't implemented: the view reports `error:` and the still shows. **macOS** isn't built
  (the Apple implementation targets iOS only).
- **Assets on iOS** come from the app bundle, so a `.riv` changed by an over-the-air update isn't seen until the next
  binary. URLs load at run time on both platforms.

## Roadmap: `RiveUIView` on iOS

The move to `RiveUIView` waits on two Exact changes, sent as Exact feedback 43fc3575:

1. A native view's own accessibility elements reaching VoiceOver. Today `RiveUIView` builds the file's elements,
   but Exact's native-view box doesn't pass them on.
2. Display-link views on the agent's virtual clock. Today `clock +N` doesn't move `RiveUIView`, so tests that wait
   for a trigger would wait on the wall clock.

When both ship, or when Rive removes `RiveView`, only `apple/Player.swift` changes. It is the one file that touches
RiveRuntime; `apple/RiveModule.swift` (props, clock, pausing, events) stays as it is.

## Upgrading Rive

The runtime versions are pinned in two places. Upgrade both together and run both platforms' tests.

- **iOS:** `exactVersion` in `apple/exact.json`. Then in each app, `bun exact.mjs lock` and commit the new
  `Package.resolved`.
- **Web:** replace `web/rive/canvas_advanced_single.mjs` with the same file from
  `npm pack @rive-app/canvas-advanced-single@<version>`, unchanged, and update the version in this README.
  The file must match `@rive-app/canvas-advanced`'s API at that version.

## The example and its tests

`example/` is an Exact app that plays `example/assets/sample.riv`. The file is built with the
[Rive CLI](https://rive.app/docs/cli/getting-started) from `example/rive-src/scene.rml`
(`cd example/rive-src && rive . --publish=local && cp build/sample.riv ../assets/`). Its view model has one
property of each type, and it fires a trigger of its own when each value arrives, so the tests check from the
file's side.

```sh
cd example
(cd .. && bun link) && bun install          # links the package, never copies it
bun exact.mjs test web
bun exact.mjs lock && EXACT_SIM=<simulator udid> bun exact.mjs test ios
```

The tests cover loading, each property type (with an escaped string), a trigger and its round trip, a legacy
event, a missing name's warning, a file that can't load, hiding, and reduced motion.

The example uses the Exact checkout at `example/.exact/checkout` (`EXACT=<checkout>` overrides it).

## Credits and licences

exact-rive is MIT licensed (see `LICENSE`). It ships Rive's runtimes, which are MIT licensed by Rive:
`licenses/rive-wasm-LICENSE.txt` covers the vendored web runtime, and `licenses/rive-ios-LICENSE.txt` covers
rive-ios, which Swift Package Manager fetches. The example's font is Nunito, under the SIL Open Font License
(`licenses/Nunito-OFL.txt`).
