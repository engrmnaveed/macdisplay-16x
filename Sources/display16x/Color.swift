import DisplayCore
import Foundation

// The v0.4 verbs, `hdr` and `color`. Each builds one command for the running app. Every
// feature they reach is also an ordinary feature for get, set and help.

/// The words after `hdr` or `color` and the action.
@MainActor private var colorWords: [String] { Array(arguments.positional.dropFirst(2)) }

@MainActor
func hdrVerb() -> Never {
    var options = CommandOptions()
    options.timedRevert = arguments.flags.contains("--try")
    let action = arguments.positional.dropFirst().first ?? "show"
    switch action.lowercased() {
    case "show":
        send(command(.get, .hdr), arguments: arguments)
    case "on", "off":
        send(command(.set, .hdr, value: .flag(action.lowercased() == "on"), options: options), arguments: arguments)
    case "toggle":
        send(command(.toggle, .hdr, options: options), arguments: arguments)
    case "headroom":
        send(command(.get, .headroom), arguments: arguments)
    case "protect":
        send(command(.set, .protectHDR, value: parseValue(colorWords.first ?? "on", for: feature(named: "protectHDR"))), arguments: arguments)
    case "night-shift":
        let value = colorWords.first
        send(Command(value == nil ? .get : .set, .nightShiftInHDR, value: value.map { parseValue($0, for: feature(named: "nightShiftInHDR")) }, origin: .command), arguments: arguments)
    case "hardware-brightness":
        let value = colorWords.first
        send(command(value == nil ? .get : .set, .hardwareInHDR, value: value.map { parseValue($0, for: feature(named: "hardwareInHDR")) }), arguments: arguments)
    case "controls":
        let value = colorWords.first
        send(Command(value == nil ? .get : .set, .hdrControls, value: value.map { parseValue($0, for: feature(named: "hdrControls")) }, origin: .command), arguments: arguments)
    default:
        fail("hdr takes show, on, off, toggle, headroom, protect, night-shift, hardware-brightness or controls", .usage)
    }
}

@MainActor
func colorVerb() -> Never {
    var options = CommandOptions()
    options.timedRevert = arguments.flags.contains("--try")
    let action = arguments.positional.dropFirst().first ?? "profile"
    let value = colorWords.isEmpty ? nil : colorWords.joined(separator: " ")
    switch action.lowercased() {
    case "profile":
        guard let value else { send(command(.get, .colorProfile), arguments: arguments) }
        send(command(.set, .colorProfile, value: .choice(value), options: options), arguments: arguments)
    case "hdr-profile":
        send(command(value == nil ? .get : .set, .hdrProfile, value: value.map(CommandValue.choice)), arguments: arguments)
    case "fallback":
        send(command(value == nil ? .get : .set, .profileFallback, value: value.map(CommandValue.choice)), arguments: arguments)
    case "protect":
        send(command(.set, .protectProfile, value: parseValue(value ?? "on", for: feature(named: "protectProfile"))), arguments: arguments)
    case "profiles":
        send(Command(.get, .profiles, origin: .command), arguments: arguments)
    case "preset":
        guard let value else { send(command(.get, .referencePreset), arguments: arguments) }
        send(command(.set, .referencePreset, value: .choice(value), options: options), arguments: arguments)
    case "modes":
        send(command(.get, .colorMode), arguments: arguments)
    case "dithering":
        send(command(.get, .dithering), arguments: arguments)
    case "rates":
        send(command(.get, .linkRates), arguments: arguments)
    case "controls":
        send(Command(value == nil ? .get : .set, .profileControls, value: value.map { parseValue($0, for: feature(named: "profileControls")) }, origin: .command), arguments: arguments)
    default:
        fail("color takes profile, hdr-profile, fallback, protect, profiles, preset, modes, dithering, rates or controls", .usage)
    }
}
