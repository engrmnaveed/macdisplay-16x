import AppKit
import DisplayCore
import DisplaySystem

// Display 16X: the menu bar app.
//
//   --safe      Start in safe mode: nothing is restored or reapplied automatically.
//               Holding Shift while the app starts does the same.
//   --verbose   Log debug detail, and echo the log to standard error.

let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    Display 16X \(AppPaths.version)
      --safe      Start in safe mode. Nothing is restored or reapplied automatically.
      --verbose   Log debug detail, and echo the log to standard error.
    Use the display16x command for scripting.
    """)
    exit(0)
}

var options = LaunchOptions()
options.safeMode = arguments.contains("--safe")
options.verbose = arguments.contains("--verbose")
LogCenter.shared.setVerbose(options.verbose)
LogCenter.shared.add(sink: SystemLogSink(echo: options.verbose))

let delegate = AppDelegate(options: options)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
