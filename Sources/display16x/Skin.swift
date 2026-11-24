import DisplayCore
import Foundation

// The `skin` verb. It builds one command for the running app, the same one
// `display16x set skin` and the settings window send.

@MainActor
func skinVerb() -> Never {
    let words: [String] = Array(arguments.positional.dropFirst())
    guard !words.isEmpty, words.first?.lowercased() != "show" else {
        send(Command(.get, .skin, origin: .command), arguments: arguments)
    }
    let text: String = words.joined(separator: " ")
    if case .failure(let refusal) = SkinRequest.parse(text) { fail(refusal.reason, .usage) }
    send(Command(.set, .skin, value: .choice(text), origin: .command), arguments: arguments)
}
