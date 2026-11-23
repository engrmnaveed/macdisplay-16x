import DisplayCore
import DisplaySystem
import Foundation

// The v0.3 verbs, `override` and `virtual`. Each builds one command for the running app.
// Listing and removing overrides also work without the app, from the files themselves,
// so what the app wrote can be taken away after a crash or once the app is gone.

/// The words after `override` or `virtual` and the action.
@MainActor private var words: [String] { Array(arguments.positional.dropFirst(2)) }

@MainActor
func overrideVerb() async -> Never {
    let action = arguments.positional.dropFirst().first ?? "show"
    var options = CommandOptions()
    options.confirmed = arguments.flags.contains("--confirm")
    switch action {
    case "show":
        send(command(.get, .scaling), arguments: arguments)
    case "add", "remove", "flexible", "native", "default", "name", "role", "clear":
        let change = ([action] + words).joined(separator: " ")
        send(command(.set, .scaling, value: .choice(change)), arguments: arguments)
    case "preview":
        send(Command(.get, .overridePreview, origin: .command), arguments: arguments)
    case "apply":
        send(Command(.perform, .overrideApply, origin: .command, options: options), arguments: arguments)
    case "discard":
        send(Command(.perform, .overrideDiscard, value: words.first.map(CommandValue.choice), origin: .command), arguments: arguments)
    case "activate":
        send(command(.perform, .overrideActivate), arguments: arguments)
    case "list":
        await sendOrWithoutApp(Command(.get, .overrides, origin: .command)) { standaloneList() }
    case "delete":
        var built = command(.perform, .overrideRemove, value: words.first.map(CommandValue.choice), options: options)
        if built.selector == nil, built.value == nil { fail("name a display, a model as VENDOR-PRODUCT, or all", .usage) }
        built.options = options
        if words.first?.lowercased() == "all" {
            await sendOrWithoutApp(built) { await standaloneDeleteAll(confirmed: options.confirmed) }
        }
        send(built, arguments: arguments)
    case "undo":
        send(command(.perform, .overrideUndo, value: words.first.map(CommandValue.choice), options: options), arguments: arguments)
    case "reset":
        send(Command(.perform, .fullReset, value: words.first.map(CommandValue.choice), origin: .command, options: options), arguments: arguments)
    case "put-back":
        send(Command(.perform, .putBackSystem, origin: .command, options: options), arguments: arguments)
    default:
        fail("override takes show, add, remove, flexible, native, default, name, role, clear, preview, apply, discard, activate, list, delete, undo, reset or put-back", .usage)
    }
}

@MainActor
func virtualVerb() -> Never {
    let action = arguments.positional.dropFirst().first ?? "list"
    var options = CommandOptions()
    options.confirmed = arguments.flags.contains("--confirm")
    func named() -> String {
        guard let name = words.first else { fail("name the virtual screen, or all", .usage) }
        return name
    }
    switch action {
    case "list":
        send(Command(.get, .virtualList, origin: .command), arguments: arguments)
    case "create", "edit":
        let spec = named() + ";" + words.dropFirst().joined(separator: " ")
        send(command(.set, action == "create" ? .virtualCreate : .virtualEdit, value: .choice(spec)), arguments: arguments)
    case "connect":
        send(Command(.set, .virtualConnect, value: .choice(named()), origin: .command), arguments: arguments)
    case "disconnect":
        send(Command(.set, .virtualDisconnect, value: .choice(named()), origin: .command), arguments: arguments)
    case "reconnect":
        send(Command(.set, .virtualReconnect, value: .choice(named()), origin: .command), arguments: arguments)
    case "discard":
        send(Command(.set, .virtualDiscard, value: .choice(named()), origin: .command, options: options), arguments: arguments)
    default:
        fail("virtual takes list, create, edit, connect, disconnect, reconnect or discard", .usage)
    }
}

/// Sends to the app, and runs `fallback` when the app is not running.
@MainActor
func sendOrWithoutApp(_ command: Command, fallback: @MainActor () async -> Never) async -> Never {
    if UnixSocketClient(path: AppPaths().socketPath).isServerAlive { send(command, arguments: arguments) }
    print("Display 16X is not running. Reading the override files themselves.")
    await fallback()
}

/// The files with the app's marker, and the ledger's folders for them.
@MainActor
private func found(_ writer: SystemFileAdministrator, _ ledger: SystemFileLedger) -> [(model: ModelKey, createdFolders: [String], request: OverrideRequest?)] {
    writer.files(under: OverrideFile.root).compactMap { path in
        guard let model = OverrideFile.model(at: path), let data = writer.contents(of: path), OverrideFile.isOurs(data) else { return nil }
        let folders = ledger.document.files.first { $0.path == path }?.createdFolders ?? []
        return (model, folders, OverrideFile.request(in: data, model: model))
    }
}

@MainActor
private func tools() -> (SystemFileAdministrator, SystemFileLedger) {
    let paths = AppPaths()
    return (SystemFileAdministrator(staging: paths.systemFilesStaging), SystemFileLedger(persistence: FilePersistence(url: paths.systemFilesLedger)))
}

@MainActor
func standaloneList() -> Never {
    let (writer, ledger) = tools()
    let files = found(writer, ledger)
    if files.isEmpty { print("No override file written by Display 16X is on this Mac.") }
    for file in files {
        print(OverrideFile.path(file.model))
        for line in file.request?.summary ?? [] { print("  \(line)") }
    }
    for moved in ledger.document.files where moved.purpose == .systemDisplaySettings {
        print("\(moved.path) moved aside to \(moved.backup ?? "?")")
    }
    exit(ExitCode.success.rawValue)
}

@MainActor
func standaloneDeleteAll(confirmed: Bool) async -> Never {
    let (writer, ledger) = tools()
    let files = found(writer, ledger)
    guard !files.isEmpty else {
        print("No override file written by Display 16X is on this Mac.")
        exit(ExitCode.success.rawValue)
    }
    let plan = OverridePlanner.remove(files.map { ($0.model, $0.createdFolders) }, affected: [], mainIsAffected: false)
    print(plan.preview)
    guard confirmed else { fail("this deletes files as administrator. Read the preview above, then add --confirm", .failed) }
    ledger.begin(plan, model: nil, now: Date())
    let outcome = await writer.run(plan)
    if case .success = outcome { ledger.finish(plan, succeeded: true) } else { ledger.finish(plan, succeeded: false) }
    switch outcome {
    case .success:
        print("Removed. Reconnect the displays, or log out and in, so macOS forgets the sizes.")
        exit(ExitCode.success.rawValue)
    case .failure(let error):
        fail(error.reason, .failed)
    }
}
