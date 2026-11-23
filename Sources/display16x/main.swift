import DisplayCore
import DisplaySystem
import Foundation

// display16x: the command line tool.
//
// `probe` runs on its own and never needs the app. Everything else builds one command,
// sends it to the running app over the user-only socket, and prints the result. This
// tool never starts the app.

enum ExitCode: Int32 {
    case success = 0
    case failed = 1
    case usage = 2
    case appNotRunning = 3
    case timeout = 4
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data(("display16x: " + message + "\n").utf8))
    exit(code.rawValue)
}

let usage = """
display16x \(AppPaths.version) — command line for Display 16X

  display16x probe [--capabilities] [--modes] [--with-log]
      Print a read-only hardware report. Works without the app.
  display16x probe --interfaces
      Only which private interfaces resolve. Looks at no display.
  display16x probe --color
      The private interfaces, then HDR and color only. Sends nothing to a monitor.

  display16x list                         Connected and remembered displays
  display16x status                       App state
  display16x features                     Every feature and what can be done with it

  display16x help [<feature>]             Help for one feature, with values and an example

  display16x get <feature> [<value>] <display> [--stored]
  display16x set <feature> <value> <display> [--confirm] [--no-verify] [--exact] [--try]
  display16x step <feature> <+N|-N> <display> [--fine]
  display16x toggle <feature> [<value>] <display>
  display16x perform <feature> [<value>] [<display>]
  display16x keep [<display>]             Keep a mode change that is waiting, or without a
                                          display, a layout or connection change
  display16x revert [<display>]           Go back to the mode, or the layout, before it

  display16x arrangement                  Where every display is
  display16x disconnect <display> [--try]  Take a display out of use without unplugging it
  display16x reconnect <display> | --all  Bring back displays the app disconnected
  display16x preset list | apply NAME | save NAME [modes,rotation,layout,brightness] | delete NAME
  display16x shortcut list | remove KEYS | add KEYS <set|step|toggle|perform> <feature> [<value>] [<display>]
  display16x settings export [FILE] | import FILE --confirm | reset --confirm

  display16x override [show] <display>    The display's model: its panel, what macOS offers,
                                          what is installed and what waits to be written
  display16x override add|remove WIDTHxHEIGHT [hidpi|low] <display>
  display16x override flexible [FROM-TO/STEP] | native SIZE | default SIZE | name NAME
                     | role monitor|television | clear  <display>
                                          Change what waits to be written for the model
  display16x override preview             Everything apply would write, every byte
  display16x override apply [--confirm]   Write as administrator, then reconnect to finish
  display16x override discard [VENDOR-PRODUCT]   Forget what waits to be written
  display16x override activate <display>  Reconnect so macOS reads the file, then check
  display16x override list                Every override Display 16X wrote. Works without
                                          the app, from the files themselves
  display16x override delete <display>|VENDOR-PRODUCT|all [--confirm]
                                          Remove overrides. "all" works without the app
  display16x override undo <display>|VENDOR-PRODUCT [--confirm]
  display16x override reset [system] [--confirm]   Remove every override, and with system
                                          move the system's saved display settings aside
  display16x override put-back [--confirm]  Put the system's display settings back

  display16x virtual list
  display16x virtual create NAME [OPTIONS…] [<display> to match or link]
  display16x virtual edit NAME OPTIONS… [<display> to link]
  display16x virtual connect|disconnect|reconnect NAME|all
  display16x virtual discard NAME|all [--confirm]
      OPTIONS: 16:9  2560x1440  hidpi|lodpi  @60,120  portrait  step=160  smallest=1280
      cap=12  modes=2560x1440,1920x1080  diagonal=27  match  connect  link  unlink
      with-display=on|off  mirror=on|off  follow-rotation=on|off  restore-layout=on|off

  <display>   --tag N | --name "NAME" | --uuid UUID | --main | --pointer | --focused | --all
  <other>     --of-tag N | --of-name "NAME" | --of-uuid UUID | --of-main | --of-pointer
              The other display, for placement and mirroring

  Anything written outside the app's folder, such as an override, prints its preview and
  changes nothing until --confirm is added. macOS then asks for an administrator password.
  <value>     0 to 1, or a percentage such as 60%, min or max. A leading + or - makes it
              an offset. on or off for switches. WIDTHxHEIGHT, default, native or previous
              for resolution, Hz for refreshRate, degrees for rotation, an input name for
              input, X,Y for position, left:end and the like for placement.
  KEYS        Modifiers and a key joined by +, for example ctrl+opt+1 or cmd+shift+f13

  --try                              For resolution, refreshRate and rotation: ask Keep or
                                     Revert on screen, and go back on its own after a few
                                     seconds. Answer with "display16x keep" or "revert"
  --controller ddc|native|software   Address one controller instead of the control's owner
  --timeout SECONDS                  How long to wait for the app (default 10)
  --json                             Print the raw result

Every display gets one line: confirmed (read back from the device), accepted (sent or
stored, not proven), or failed with the reason.
"""

// MARK: Arguments

struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    static let valueOptions: Set<String> = ["--tag", "--name", "--uuid", "--timeout", "--controller", "--of-tag", "--of-name", "--of-uuid"]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let item = raw[index]
            if Arguments.valueOptions.contains(item) {
                guard index + 1 < raw.count else { fail("\(item) needs a value", .usage) }
                values[item] = raw[index + 1]
                index += 2
            } else if item.hasPrefix("--") {
                flags.insert(item)
                index += 1
            } else {
                positional.append(item)
                index += 1
            }
        }
    }

    var selector: DisplaySelector? {
        var found: [DisplaySelector] = []
        if let tag = values["--tag"] {
            guard let number = Int(tag) else { fail("--tag needs a number", .usage) }
            found.append(.tag(number))
        }
        if let name = values["--name"] { found.append(.name(name)) }
        if let uuid = values["--uuid"] { found.append(.uuid(uuid)) }
        if flags.contains("--main") { found.append(.main) }
        if flags.contains("--pointer") { found.append(.underPointer) }
        if flags.contains("--focused") { found.append(.focused) }
        if flags.contains("--all") { found.append(.all) }
        if found.count > 1 { fail("name one display: use only one of --tag, --name, --uuid, --main, --pointer, --focused, --all", .usage) }
        return found.first
    }

    /// The other display of a command between two displays.
    var secondSelector: DisplaySelector? {
        var found: [DisplaySelector] = []
        if let tag = values["--of-tag"] {
            guard let number = Int(tag) else { fail("--of-tag needs a number", .usage) }
            found.append(.tag(number))
        }
        if let name = values["--of-name"] { found.append(.name(name)) }
        if let uuid = values["--of-uuid"] { found.append(.uuid(uuid)) }
        if flags.contains("--of-main") { found.append(.main) }
        if flags.contains("--of-pointer") { found.append(.underPointer) }
        if found.count > 1 { fail("name one other display: use only one of --of-tag, --of-name, --of-uuid, --of-main, --of-pointer", .usage) }
        return found.first
    }

    var timeout: TimeInterval {
        guard let text = values["--timeout"] else { return 10 }
        guard let seconds = TimeInterval(text), seconds > 0 else { fail("--timeout needs a number of seconds", .usage) }
        return seconds
    }

    var controller: ControllerKind? {
        guard let text = values["--controller"] else { return nil }
        switch text.lowercased() {
        case "ddc": return .ddc
        case "native": return .appleNative
        case "software": return .softwareGamma
        default: fail("--controller is ddc, native or software", .usage)
        }
    }
}

func parseValue(_ text: String, for feature: FeatureDescriptor) -> CommandValue {
    switch CommandValueParser.parse(text, for: feature) {
    case .success(let value): return value
    case .failure(let refusal): fail(refusal.reason, .usage)
    }
}

// MARK: Sending

func send(_ command: Command, arguments: Arguments) -> Never {
    if let problem = FeatureRegistry.withColor.validate(command) { fail(problem, .usage) }
    let client = UnixSocketClient(path: AppPaths().socketPath)
    let result: CommandResult
    do {
        result = try client.execute(command, timeout: arguments.timeout)
    } catch {
        switch error {
        case .appNotRunning: fail(error.message, .appNotRunning)
        case .timeout: fail(error.message, .timeout)
        default: fail(error.message, .failed)
        }
    }
    if arguments.flags.contains("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result) { print(String(decoding: data, as: UTF8.self)) }
    } else {
        for entry in result.entries { print(entry.line) }
        if let report = result.report { print(report) }
    }
    if let error = result.error { fail(error, .failed) }
    exit(result.succeeded ? ExitCode.success.rawValue : ExitCode.failed.rawValue)
}

func feature(named name: String?) -> FeatureDescriptor {
    guard let name else { fail("name a feature. Run \"display16x features\" for the list", .usage) }
    let registry = FeatureRegistry.withColor
    guard let match = registry.ordered.first(where: { $0.id.rawValue.lowercased() == name.lowercased() }) else {
        fail("unknown feature \"\(name)\". Run \"display16x features\" for the list", .usage)
    }
    return match
}

// MARK: Entry

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
guard let verb = arguments.positional.first else {
    print(usage)
    exit(arguments.flags.contains("--help") ? ExitCode.success.rawValue : ExitCode.usage.rawValue)
}
if arguments.flags.contains("--help") {
    print(usage)
    exit(ExitCode.success.rawValue)
}
var options = CommandOptions()
options.controller = arguments.controller

/// A command with the second display filled in from --of-… flags.
func command(_ operation: CommandOperation, _ feature: FeatureID, value: CommandValue? = nil, options: CommandOptions = CommandOptions()) -> Command {
    var built = Command(operation, feature, on: arguments.selector, value: value, origin: .command, options: options)
    built.secondSelector = arguments.secondSelector
    return built
}

/// The positional words after the verb and the feature.
var rest: [String] { Array(arguments.positional.dropFirst(2)) }

switch verb {
case "help":
    if let name = arguments.positional.dropFirst().first {
        let target = feature(named: name)
        print(FeatureRegistry.withColor.helpWithColor(for: target.id) ?? usage)
    } else {
        print(usage)
    }

case "features":
    print("Features\n" + FeatureRegistry.withColor.help() + "\n\nRun \"display16x help FEATURE\" for its values and an example.")

case "probe":
    var probeOptions = ProbeOptions()
    probeOptions.includeCapabilities = arguments.flags.contains("--capabilities")
    probeOptions.includeAllModes = arguments.flags.contains("--modes")
    probeOptions.interfacesOnly = arguments.flags.contains("--interfaces")
    probeOptions.colorOnly = arguments.flags.contains("--color")
    let lines = await HardwareProbe.report(options: probeOptions)
    print(lines.joined(separator: "\n"))
    if arguments.flags.contains("--with-log") {
        // The log lives in the running app. Without the app there is none to add.
        print("\nApp log")
        if let result = try? UnixSocketClient(path: AppPaths().socketPath).execute(Command(.get, .log, origin: .command), timeout: 3),
           let log = result.report {
            print(log.isEmpty ? "  (empty)" : log)
        } else {
            print("  Display 16X is not running, so there is no log to include.")
        }
    }

case "list":
    send(Command(.get, .displays, origin: .command), arguments: arguments)

case "status":
    send(Command(.get, .status, origin: .command), arguments: arguments)

case "arrangement":
    send(Command(.get, .arrangement, origin: .command), arguments: arguments)

case "get":
    let target = feature(named: arguments.positional.dropFirst().first)
    // Reading means asking the device, unless the stored value is asked for.
    options.refresh = !arguments.flags.contains("--stored")
    let value = rest.first.map { CommandValue.choice($0) }
    send(command(.get, target.id, value: value, options: options), arguments: arguments)

case "set":
    let target = feature(named: arguments.positional.dropFirst().first)
    guard arguments.positional.count >= 3 else { fail("set needs a value, for example: display16x set brightness 60% --main", .usage) }
    options.confirmed = arguments.flags.contains("--confirm")
    options.verification = arguments.flags.contains("--no-verify") ? .none : .readBack
    options.matching = arguments.flags.contains("--exact") ? .exact : .nearest
    options.timedRevert = arguments.flags.contains("--try")
    let value = parseValue(arguments.positional[2], for: target)
    send(command(.set, target.id, value: value, options: options), arguments: arguments)

case "step":
    let target = feature(named: arguments.positional.dropFirst().first)
    guard arguments.positional.count >= 3, let steps = Int(arguments.positional[2].replacingOccurrences(of: "+", with: "")), steps != 0 else {
        fail("step needs a number of steps, for example: display16x step brightness +1 --main", .usage)
    }
    options.timedRevert = arguments.flags.contains("--try")
    send(command(.step, target.id, value: .steps(steps, fine: arguments.flags.contains("--fine")), options: options), arguments: arguments)

case "toggle":
    let target = feature(named: arguments.positional.dropFirst().first)
    options.timedRevert = arguments.flags.contains("--try")
    send(command(.toggle, target.id, value: rest.first.map { CommandValue.choice($0) }, options: options), arguments: arguments)

case "perform":
    let target = feature(named: arguments.positional.dropFirst().first)
    options.confirmed = arguments.flags.contains("--confirm")
    options.timedRevert = arguments.flags.contains("--try")
    send(command(.perform, target.id, value: rest.first.map { CommandValue.choice($0) }, options: options), arguments: arguments)

case "keep":
    if arguments.selector == nil {
        send(Command(.perform, .keepLayout, origin: .command), arguments: arguments)
    }
    send(Command(.perform, .keepMode, on: arguments.selector, origin: .command), arguments: arguments)

case "revert":
    if arguments.selector == nil {
        send(Command(.perform, .revertLayout, origin: .command), arguments: arguments)
    }
    send(Command(.perform, .revertMode, on: arguments.selector, origin: .command), arguments: arguments)

case "disconnect":
    options.timedRevert = arguments.flags.contains("--try")
    send(command(.set, .connected, value: .flag(false), options: options), arguments: arguments)

case "reconnect":
    if arguments.flags.contains("--all") {
        send(Command(.perform, .reconnectAll, origin: .command), arguments: arguments)
    }
    send(command(.set, .connected, value: .flag(true)), arguments: arguments)

case "preset":
    let action = arguments.positional.dropFirst().first ?? "list"
    let name = rest.first
    switch action {
    case "list":
        send(Command(.get, .preset, origin: .command), arguments: arguments)
    case "apply":
        guard let name else { fail("name the preset to apply", .usage) }
        options.timedRevert = arguments.flags.contains("--try")
        send(Command(.set, .preset, value: .choice(name), origin: .command, options: options), arguments: arguments)
    case "save":
        guard let name else { fail("name the preset to save", .usage) }
        let contents = rest.dropFirst().first.map { ":" + $0 } ?? ""
        send(Command(.set, .savePreset, value: .choice(name + contents), origin: .command), arguments: arguments)
    case "delete":
        guard let name else { fail("name the preset to delete", .usage) }
        send(Command(.set, .deletePreset, value: .choice(name), origin: .command), arguments: arguments)
    default:
        fail("preset takes list, apply, save or delete", .usage)
    }

case "shortcut":
    let action = arguments.positional.dropFirst().first ?? "list"
    switch action {
    case "list":
        send(Command(.get, .shortcuts, origin: .command), arguments: arguments)
    case "remove":
        guard let keys = rest.first else { fail("name the keys, for example ctrl+opt+1", .usage) }
        send(Command(.set, .removeShortcut, value: .choice(keys), origin: .command), arguments: arguments)
    case "add":
        // shortcut add KEYS VERB FEATURE [VALUE] [display flags]
        guard rest.count >= 3, let combo = KeyNames.combo(parsing: rest[0]) else {
            fail("shortcut add needs keys, a verb and a feature, for example: display16x shortcut add ctrl+opt+1 set preset Desk", .usage)
        }
        guard let operation = CommandOperation(rawValue: rest[1]), operation != .get else { fail("the shortcut's verb is set, step, toggle or perform", .usage) }
        let target = feature(named: rest[2])
        var value: CommandValue?
        if rest.count >= 4 {
            if operation == .step {
                guard let steps = Int(rest[3].replacingOccurrences(of: "+", with: "")), steps != 0 else { fail("step needs a number of steps", .usage) }
                value = .steps(steps, fine: arguments.flags.contains("--fine"))
            } else if operation == .set {
                value = parseValue(rest[3], for: target)
            } else {
                value = .choice(rest[3])
            }
        }
        var bound = command(operation, target.id, value: value)
        bound.origin = .keyboard
        bound.options.confirmed = arguments.flags.contains("--confirm")
        if let problem = FeatureRegistry.withColor.validate(bound) { fail(problem, .usage) }
        let binding = ShortcutBinding(combo: combo, command: bound)
        guard let data = try? JSONEncoder().encode(binding) else { fail("the shortcut could not be encoded", .failed) }
        send(Command(.set, .shortcuts, value: .choice(String(decoding: data, as: UTF8.self)), origin: .command), arguments: arguments)
    default:
        fail("shortcut takes list, add or remove", .usage)
    }

case "settings":
    let action = arguments.positional.dropFirst().first ?? ""
    switch action {
    case "export":
        let client = UnixSocketClient(path: AppPaths().socketPath)
        let result: CommandResult
        do {
            result = try client.execute(Command(.get, .settingsExport, origin: .command), timeout: arguments.timeout)
        } catch {
            fail(error.message, error == .appNotRunning ? .appNotRunning : .failed)
        }
        guard let text = result.report else { fail(result.error ?? "the app sent no settings", .failed) }
        if let path = rest.first, path != "-" {
            do {
                try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                print("Settings written to \(path).")
            } catch {
                fail("the file could not be written: \(error.localizedDescription)", .failed)
            }
        } else {
            print(text)
        }
    case "import":
        guard let path = rest.first else { fail("name the file to import", .usage) }
        guard let data = FileManager.default.contents(atPath: path) else { fail("the file could not be read", .failed) }
        options.confirmed = arguments.flags.contains("--confirm")
        send(Command(.set, .settingsImport, value: .choice(String(decoding: data, as: UTF8.self)), origin: .command, options: options), arguments: arguments)
    case "reset":
        options.confirmed = arguments.flags.contains("--confirm")
        send(Command(.perform, .settingsReset, origin: .command, options: options), arguments: arguments)
    default:
        fail("settings takes export, import or reset", .usage)
    }

case "override":
    await overrideVerb()

case "virtual":
    virtualVerb()

default:
    fail("unknown command \"\(verb)\". Run \"display16x help\"", .usage)
}
