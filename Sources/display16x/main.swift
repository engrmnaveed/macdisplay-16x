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

  display16x list                         Connected and remembered displays
  display16x status                       App state
  display16x features                     Every feature and what can be done with it

  display16x get <feature> <display> [--stored]
  display16x set <feature> <value> <display> [--confirm] [--no-verify] [--exact] [--try]
  display16x step <feature> <+N|-N> <display> [--fine]
  display16x toggle <feature> <display>
  display16x keep <display>               Keep a mode change that is waiting
  display16x revert <display>             Go back to the mode before it

  <display>   --tag N | --name "NAME" | --uuid UUID | --main | --pointer | --focused | --all
  <value>     0 to 1, or a percentage such as 60%. A leading + or - makes it an offset.
              on or off for switches. WIDTHxHEIGHT for resolution, Hz for refreshRate,
              degrees for rotation, an input name for input.

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

    static let valueOptions: Set<String> = ["--tag", "--name", "--uuid", "--timeout", "--controller"]

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
    switch feature.valueKind {
    case .ranged:
        let isOffset = text.hasPrefix("+") || text.hasPrefix("-")
        let isPercent = text.hasSuffix("%")
        let digits = text.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        guard var number = Double(digits) else { fail("\"\(text)\" is not a value. Use 0 to 1, or a percentage such as 60%", .usage) }
        if isPercent {
            number /= 100
        } else if abs(number) > 1 {
            fail("\"\(text)\" is outside 0 to 1. Add % for a percentage", .usage)
        }
        return isOffset ? .offset(number) : .absolute(number)
    case .boolean, .toggleOnly:
        switch text.lowercased() {
        case "on", "true", "yes", "1": return .flag(true)
        case "off", "false", "no", "0": return .flag(false)
        default: fail("\"\(text)\" is not on or off", .usage)
        }
    case .choice:
        return .choice(text)
    case .action, .report:
        fail("\(feature.id) cannot be set", .usage)
    }
}

// MARK: Sending

func send(_ command: Command, arguments: Arguments) -> Never {
    if let problem = FeatureRegistry.standard.validate(command) { fail(problem, .usage) }
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
    let registry = FeatureRegistry.standard
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

switch verb {
case "help":
    print(usage)

case "features":
    print("Features\n" + FeatureRegistry.standard.help())

case "probe":
    var probeOptions = ProbeOptions()
    probeOptions.includeCapabilities = arguments.flags.contains("--capabilities")
    probeOptions.includeAllModes = arguments.flags.contains("--modes")
    probeOptions.interfacesOnly = arguments.flags.contains("--interfaces")
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

case "get":
    let target = feature(named: arguments.positional.dropFirst().first)
    // Reading means asking the device, unless the stored value is asked for.
    options.refresh = !arguments.flags.contains("--stored")
    send(Command(.get, target.id, on: arguments.selector, origin: .command, options: options), arguments: arguments)

case "set":
    let target = feature(named: arguments.positional.dropFirst().first)
    guard arguments.positional.count >= 3 else { fail("set needs a value, for example: display16x set brightness 60% --main", .usage) }
    options.confirmed = arguments.flags.contains("--confirm")
    options.verification = arguments.flags.contains("--no-verify") ? .none : .readBack
    options.matching = arguments.flags.contains("--exact") ? .exact : .nearest
    options.timedRevert = arguments.flags.contains("--try")
    let value = parseValue(arguments.positional[2], for: target)
    send(Command(.set, target.id, on: arguments.selector, value: value, origin: .command, options: options), arguments: arguments)

case "step":
    let target = feature(named: arguments.positional.dropFirst().first)
    guard arguments.positional.count >= 3, let steps = Int(arguments.positional[2].replacingOccurrences(of: "+", with: "")), steps != 0 else {
        fail("step needs a number of steps, for example: display16x step brightness +1 --main", .usage)
    }
    send(Command(.step, target.id, on: arguments.selector, value: .steps(steps, fine: arguments.flags.contains("--fine")), origin: .command, options: options), arguments: arguments)

case "toggle":
    let target = feature(named: arguments.positional.dropFirst().first)
    send(Command(.toggle, target.id, on: arguments.selector, origin: .command, options: options), arguments: arguments)

case "keep":
    send(Command(.perform, .keepMode, on: arguments.selector, origin: .command), arguments: arguments)

case "revert":
    send(Command(.perform, .revertMode, on: arguments.selector, origin: .command), arguments: arguments)

default:
    fail("unknown command \"\(verb)\". Run \"display16x help\"", .usage)
}
