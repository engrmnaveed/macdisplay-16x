# Core architecture

This is the design the v0.1 core is built to. It was set after a full read of the reference product's public guide (503 pages, 22 November 2026), so that later features in the [inventory](feature-inventory.md) can be added without reworking the core. The design, names and defaults are our own.

Each section says what v0.1 **implements** and what it only **reserves** (a type, an enum case or a protocol with no behavior yet). Reserve the shape and nothing more.

Revised on 23 November 2026 with what the first build learned on hardware. The evidence is in the [domain log](domain-log.md) and the [feasibility notes](feasibility.md). Decisions still open are listed in the [roadmap](roadmap.md#5-open-decisions).

## 1. Targets

| Target | Contents | May import |
| --- | --- | --- |
| `DisplayCore` | Domain model and logic: registry, identity, modes, controls, brightness composition, command engine, feature registry, event bus, automation gate, reconciler, settings, key routing policy, indicator payloads. Protocols for everything that touches the system. | Foundation |
| `DDC` | Packet codec, lenient reply parsing, per-display scheduler, quirks. The I2C transport is a protocol. | Foundation |
| `DisplaySystem` | Public macOS adapters: display inventory and modes, configuration transactions, gamma tables, reconfiguration, sleep, wake, lock and session notifications, audio output device. It implements the core's protocols and holds the adapter that turns the DDC scheduler into a controller, because `DDC` and `DisplayCore` do not import each other. | CoreGraphics, AppKit, IOKit, CoreAudio, `DisplayCore`, `DDC`, `DisplayPrivate` |
| `DisplayPrivate` | The only target that resolves private symbols (AV service I2C, native brightness, the window server's mode list and other window server calls). Every entry point is optional at run time. | IOKit |
| `Display16XApp` | Status item, panel, settings window, indicator window, key capture, login item, IPC server. | all of the above |
| `display16x` | CLI. `probe` runs standalone. Everything else is a client of the running app. | `DisplayCore`, and for `probe` only `DDC`, `DisplaySystem` and `DisplayPrivate` |

`DisplayCore` and `DDC` have no system dependencies, so their behavior is covered by unit tests with fakes. Tests use Swift Testing, because the Command Line Tools ship it and do not ship XCTest.

Sleep, wake and reconfiguration notifications only reach a process that runs an application event loop. Anything that reacts to them lives in the app, never in a bare command-line process.

## 2. Displays: saved record and live connection are separate

- **`DisplayRecord`** is persisted and outlives the connection. It carries an app-assigned **tag** (a positive integer, stable, never reused), the full set of identifiers captured at first detection (system UUID, vendor, model, numeric and text serial, product name, manufacture date, EDID hash, port location), a **match rule**, system name and custom name, kind, traits, physical size with an optional override, and last-seen time.
- **`LiveDisplay`** is the run-time view: the current system display ID, current mode, and controllers. System display IDs and UUIDs can change across wake, reconnects and OS installs, so no setting is keyed on them. They are only inputs to matching.
- **`IdentityMatcher`** binds live displays to records using the record's match rule. A global default rule applies only to displays never seen before. The default rule is `automatic`: match on the EDID identifiers, and use the system UUID and then the port location only to tell identical monitors apart. Explicit rules (UUID only, identifiers only, with port, full EDID) can be chosen per record.
- **Model key** (vendor and product) is a separate scope for settings that apply to every unit of a model.
- **State**: `connected`, `remembered`, and reserved `disconnectedByApp` and `disconnectedBySystem`.
- **Operations**: forget, reset, and transfer settings from one record to another (replace, not merge). Records unseen for a retention period are removed.
- The placeholder display macOS can report briefly during wake is not trusted. Topology is read only after reconfiguration settles.
- A display is paired with its DDC channel by comparing the identity the window server reports with the monitor's EDID. Two units that report the same identity are paired in a stable order, and the pairing is marked as a guess so the detail view can say that a command may reach the other unit.

*Implements:* everything above except the reserved states. *Reserves:*

- Kinds for virtual, Sidecar, AirPlay and DisplayLink displays.
- An alias map that links a record to the identity it reports after an EDID override.
- Relationships between two records: mirror, stream and picture-in-picture as source to target, and the association of a virtual screen with a physical display.
- Groups. A group has a membership rule (an explicit list of tags, or all connected displays minus exclusions), an activation rule, a priority and an exclusivity flag. The set of active groups is derived state, recomputed when topology changes.

## 3. Settings

Scopes: global, per model key, per record, per record and controller. Reserved: per group, per virtual screen, and a machine-wide scope for system overrides, which are shared by all users and are not part of user settings.

- Stored as one versioned, typed JSON document in Application Support, written atomically and debounced.
- Every setting is optional. Unset means "use the default" and is different from a value that equals the default.
- Turning a feature off never deletes what it saved. Removing a controller keeps its configuration.
- Export, import and reset operate on the whole settings document. *Reserved for v0.2.*
- A separate **recovery store** per Mac holds values needed to put hardware and the system back the way we found them (for example a state we changed and must restore on quit or after a crash). Reset, export and import never touch it.

## 4. Controls and controllers

A **control** is something adjustable (brightness, contrast, volume, mute, input, power). A **controller** is a mechanism that provides controls for one display. A display can have several controllers at once.

- Controller kinds implemented: `ddc`, `appleNative`, `softwareGamma`. Reserved: overlay, audio device, network device, HDMI-CEC, DisplayLink, script.
- Each controller publishes a **capability** per control: absolute, relative-only or toggle-only; readable, write-only or unknown; whether it notices outside changes; raw range; neutral value. One working control implies nothing about the others, and a failed read does not mean writes fail.
- A **resolver** picks one owning controller per control by precedence, with a manual override that stops automatic reassignment.
- **Values are normalized 0 to 1.** A per-control mapping converts to the device's raw range (minimum, maximum, curve, invert, neutral, and a code override for DDC). Raw maxima of 100, 200 and 255 all occur in the field.
- **Tracked value and device readback are different things.** The record stores the tracked value. Readback is optional and never silently replaces it. Startup policy per controller: trust the stored value (default), write it, or read the device.
- Control identifiers are stable strings shared by the UI, CLI and later automation.
- Apple-branded external displays get the native controller only. DDC is withheld from them unless the user overrides it.
- Mute is a strategy (mute command, volume to zero, or both) and remembers the volume to restore. Inputs are a per-display list of labelled entries, each mapped to a raw value and an optional alternate command for monitors that need it. Input switching and power-off ask for confirmation, because they can cut the Mac off from the monitor.
- When a monitor lists its own input values, its input list is built from them. A value the command set does not define is shown by its number until the user renames it. A monitor that lists none gets the generic list. The user's own list is never replaced.

### Which controls a monitor really has

A capabilities string can omit controls that work. A read can succeed for a control that does nothing. A write can be accepted without taking effect. None of the three is proof on its own.

- A control is offered when the monitor answers a read for it. The capabilities string is a hint and never rules a control out.
- Only a write that reads back as the new value proves a control works. When two changes made by hand in a row read back unchanged, the control is marked **reported and ignored**. It leaves the card, stays in the detail view with that reason, and can be checked again.
- Automatic restores never count as evidence, and neither does anything during a wake transition, because a monitor that is not ready ignores writes too.
- A mute that works by "volume to zero" goes away together with the volume control.

### DDC transport

One serial queue per display by default, with a reserved option to share one queue between monitors that interfere with each other. The newest request for a control replaces queued ones. Tunable per display: repeat count per write, repeat count per query, gap between commands, retry count and backoff, read delay, and tolerance for bad checksums and headers. Never block the main thread.

- **Queries are sent twice by default.** Both test monitors drop or refuse a single query. Writes are also sent twice by default, although both test monitors accept a single write.
- **A reply is an answer only if it names the feature that was asked for.** Other programs on the same channel receive each other's replies.
- The null message and uniform filler bytes count as no reply and are retried. A reply with a garbled header is accepted when its checksum matches the standard frame. A reply whose checksum cannot match is read twice and has to agree with itself.
- **Silence is not proof that a monitor lacks DDC.** A probe that gets no answer keeps what was learned before. After a connect or a wake the monitor is asked again a few bounded times, then left alone until the next wake or until the panel opens.
- **Nothing automatic talks to a monitor while the displays are asleep.** If the app starts while they are asleep, it behaves as if it had seen them go to sleep.

Reads happen at connect, on an explicit refresh, and while the panel is open. Nothing reads on a background timer. Periodic readback is not planned.

## 5. Brightness is one scale built from parts

`brightness` is a composite control over three addressable parts: `softwareBrightness` below a switchover point, `hardwareBrightness` across the hardware range, and reserved upscaling above it. Parameters per display: switchover point, hardware floor, whether zero may turn the image fully black.

- On the composite scale, 0 to 1 covers software dimming and the hardware range, and 1 is the top of the hardware range. Upscaling, when it exists, is addressed as values above 1. A mapping from the scale to nits per display is reserved.
- Safety floors: automatic restores never go below a minimum level, and keys and scrolling cannot reach black unless the user allowed it.

### The color pipeline

Dimming, color temperature, gamma and gain, inversion, lookup tables and upscaling all end up in the same per-display color table, so no feature writes that table directly.

- A **`ColorPipeline`** per display holds an ordered list of stages. Each stage contributes a transform. The pipeline composes them and writes the table once. It can be suspended and reset to neutral as a whole.
- v0.1 implements the pipeline with one stage, software dimming. The other stages are reserved.
- The pipeline writes through a backend protocol. v0.1 implements the gamma-table backend and reports which backend is active. Overlay window and compositor-filter backends are reserved.
- **The pipeline cannot check its own table.** macOS puts its own table back around an unlock without a reconfiguration event, and a process that has set a table keeps reading its own table back after the system has stopped using it. So tables are written again without checking: on reconfiguration, wake, unlock and the return of the user's session, at a few bounded moments after each, and when the panel opens. Never on a repeating timer. Tables are cleared on quit.
- A value with a software share is reported as `accepted`, never `confirmed`. The interface shows what the app last wrote.
- During a drag the software part is applied before the hardware part, so the picture follows the pointer while the monitor catches up.
- Before using the gamma-table backend, check whether any connected display has a custom color profile and whether the result is safe. This is still unverified, and software dimming stays off by default until it is.

## 6. One command engine for every surface

The menu, keys, CLI, and later URL and Shortcuts actions all build a `Command` and hand it to one `CommandEngine`. The UI never calls a controller directly.

- **`Command`**: operation (get, set, step, toggle, perform), selector, feature, value (absolute or offset, normalized), origin, and options (controller specifier, skip propagation, exact or nearest matching, ask for the Keep or Revert countdown). A reserved second selector names the other display for operations between two displays, such as mirroring, relative placement and swapping records.
- **`FeatureRegistry`**: each feature declares its scope, value kind (ranged, Boolean, toggle-only, choice, action, report), supported operations and required capabilities. Validation, CLI help and UI availability all come from it.
- **`Selector`**: tag, name, system UUID, main, under the pointer, focused, all. Remembered displays are valid targets. A missing or ambiguous selector fails before any side effect. No surface silently targets every display.
- **`CommandResult`**: one ordered entry per display, each `confirmed` with the value read back, `accepted` but unconfirmed, or `failed` with a reason. Requested and actual values are both reported.
- **Origin** on every change: interface, keyboard, command, sync, outside change, restore, startup. Reserved consumers (sync, protection) depend on it to avoid loops.
- A **preset** is a named, ordered list of commands replayed through the engine. *Reserved for v0.2.*
- Further surfaces (URL scheme, Shortcuts actions, a local HTTP listener, an in-app console) are thin clients of the engine, each with its own enable switch. *Reserved.*

## 7. Events, the automation gate and the reconciler

- **Event bus**, typed: app launched and terminating; display added, removed, controllers ready; reconfiguration began and settled (debounced); sleep; wake, then wake settled after a delay; lock and unlock; session active and inactive; mode changed (rotation included); mode confirmation changed; value changed; gate changed; permissions changed; settings changed. Delays are settings. Nothing polls. Sleep is taken from the notification, because the per-display "asleep" flag lags behind it. A size change on one display is reported by macOS as a move of that display, so a consumer that watches for arrangement changes must not count those. Reserved events: disconnect and reconnect by the app as distinct from physical ones, screen saver start and stop, lid open and close, audio output changed, capture stopped, active groups changed.
- **`AutomationGate`**: every automatic write (restore, reapply, and later protection, sync and auto-connect) passes through one gate. It is closed until startup finishes, during sleep, while another user's session is active, and in **safe mode** (Shift held through the first 0.8 seconds of launch, or `--safe`). Safe mode does nothing automatic at all. Even an unconfirmed mode change left by a crash waits in the recovery store for the next normal start.
- **Reconciler**: holds desired state per record and reapplies it on wake settled and on reconnect, through the gate. A pending-restore queue is persisted and retried when the same record reappears. Only ranged and on/off values are restored, never one-shot actions such as input switching.
- **Only a value the user set through the app is desired state.** A value that was only read from the monitor is a belief and is never written back. Seeing another value on the monitor ends the restore of that control. A value set on a remembered display is stored and applied when the display returns.
- **A wake is not a standby.** The idle timer followed by a mouse move produces a sleep and wake pair, many times a day, and the monitors lose nothing. DDC has no change notifications, so after a wake the app cannot tell a monitor that forgot a value from a user who changed it elsewhere. The default for DDC values after wake is an [open decision](roadmap.md#5-open-decisions). Software dimming is not part of that question: it lives in the app and is always written again.
- Wake and reconnect work runs as an **ordered pipeline of stages**: link and adapter recovery (reserved), configuration restore (reserved), value restore (implemented), protection and group layout (reserved). A stage can be added without reordering the others.
- A **connection policy** is the single place that decides whether a display may be disconnected: it never removes the last eligible physical display, and it carries model and lid rules. Multi-step connection changes are cancellable and are cancelled by sleep and user switching. *Reserved for v0.2.*

*Implements:* the bus, the gate, and restoring DDC and software brightness. *Reserves:* desired mode, rotation, HDR and arrangement targets (configuration protection, v0.2).

## 8. Modes

- **The mode list comes from the window server's own list**, a private interface that is optional at run time. The public list hides scaled HiDPI modes unless the display is on one, which breaks both the size strip and the way back from a change. The public list supplies exact refresh rates and the safe flag for the modes it knows, and is used alone, with those limits, when the private list is missing or does not look right.
- **`ModeDescriptor`**: logical size, pixel size, scale, refresh rate, bit depth, and flags (native, default, safe). Depth cannot be told apart through the public interface and is always 8 for now. Reserved: variable refresh range, notch variant, and connection-level format as a separate layer.
- Modes are persisted and matched by attributes, never by system mode number. The window server's number is used only at the moment of applying a mode the public list hides, inside an ordinary configuration transaction.
- **`ModeRequest`** is partial (any of size, HiDPI, refresh, depth). The resolver returns an exact match or the nearest with the deviation reported. It resolves in a fixed order: size, then density, then refresh rate, then depth.
- A shared **filter chain** (native aspect ratio, minimum height, remove duplicates, hide modes the system does not mark safe, always keep the current mode) feeds the list, the size strip and shortcuts.
- **The size strip does not depend on the mode in use.** On a display that offers HiDPI it shows the HiDPI sizes and ends at the panel's own unscaled size. When no default-flagged mode has the current density, the native-flagged mode of that density is the default size.
- **Apply, verify, report**: apply in a persistent configuration transaction, wait for reconfiguration to settle, read the mode back, and report requested versus actual. Every change emits `modeChanged` with its origin.
- **Timed revert** applies to interactive changes (origin interface) and to any command that asks for the countdown. Other changes from the CLI, shortcuts, presets and restores apply without one, because nobody is there to confirm. A second change during the countdown restarts it and still reverts to the mode in use before the first. The recovery store holds the unconfirmed mode and the unconfirmed rotation.
- Each record keeps favourite modes and the previous mode.

## 9. Keys and the indicator

- **Capture** is a strategy. v0.1 implements an event tap (needs Accessibility permission). A no-permission strategy is a spike.
- **Engagement**: claim brightness keys only when the target display is one we control. Claim volume keys only when the current audio output belongs to a display we control, so headphones and speakers keep working. Otherwise pass the key to macOS.
- **Target**: display under the pointer (default), focused display, or all. Each display can opt out.
- **Steps**: a logical scale with standard and fine steps, shown as 16 segments. A fine step can be smaller than a monitor's raw step, so the tracked value keeps the exact position even when the hardware does not move.
- A command that was issued counts as handled.
- **Indicator**: value changes with keyboard origin produce an `IndicatorPayload` (control, value, segments, display). A presenter protocol draws it on the affected display. v0.1 ships one presenter.

## 10. Permissions and privilege

A permission broker tracks Accessibility and login-item status as state and tells the user what is missing. macOS ties the Accessibility grant to the code signature, so an entry left by an earlier build can look right and block the grant. When the grant is still missing after the user was sent to System Settings, the notice says to remove the old entry and add it again. A grant takes effect while the app is running. Builds need a stable signing identity for the grant to survive a rebuild. Reserved: Input Monitoring, Screen Recording, and a staged privileged path (pending, apply with administrator approval, activate or reboot, undo) for system overrides.

## 11. CLI and IPC

The app listens on a user-only Unix socket in its Application Support folder. The CLI sends one `Command` as JSON and prints the `CommandResult`, with a timeout and a clear message when the app is not running. It never launches a second app instance. `display16x probe` works without the app. A mode or rotation change can ask for the countdown with `--try`, and `display16x keep` or `revert` answers it.

## 12. Logging and reserved services

- **Logging** uses the system log with one category per target, a `--verbose` launch flag, and a small bounded in-memory log that `display16x probe` can include in a bug report. *Implemented.*
- Reserved as named services with no behavior in v0.1: power assertions (keep awake while a display is connected, and short guards around risky operations), link and adapter reset, link diagnostics as report-kind features, user notices, an updater, a capture pipeline for picture-in-picture and streams, audio processing, color profile selection and editing, device sensors and lights, and system appearance toggles. Each plugs into the feature registry, the event bus or the wake pipeline. None needs a change to the core types.

