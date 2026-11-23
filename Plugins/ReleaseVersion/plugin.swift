import Foundation
import PackagePlugin

/// Writes the release version into the code of the target that uses this plugin.
///
/// `scripts/release-version` is the one place the version is written. The packaging
/// script reads it for the bundle, and this plugin turns it into
/// `let releaseVersion = "X.Y.Z"` for the app and the command line tool, on every build,
/// `swift test` included. A version that is not three numbers stops the build.
@main
struct ReleaseVersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let input = context.package.directoryURL.appending(path: "scripts/release-version")
        let output = context.pluginWorkDirectoryURL.appending(path: "ReleaseVersion.swift")
        return [
            .buildCommand(
                displayName: "Reading the version from scripts/release-version",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", Self.script, "release-version", input.path, output.path],
                inputFiles: [input],
                outputFiles: [output]
            ),
        ]
    }

    /// Plain shell, so the plugin needs no tool of its own. $1 is the version file, $2 the
    /// Swift file to write. Builtins only: in SwiftPM's build sandbox a command
    /// substitution such as $(cat file) comes back empty.
    static let script = #"""
        set -eu
        version=''
        IFS= read -r version < "$1" || true
        case "$version" in
            *[!0-9.]* | '' | .* | *. | *..* | *.*.*.* ) valid=no ;;
            *.*.* ) valid=yes ;;
            * ) valid=no ;;
        esac
        if [ "$valid" != yes ]; then
            echo "error: scripts/release-version must hold three numbers such as 0.1.0, not '$version'" >&2
            exit 1
        fi
        printf '// Generated from scripts/release-version by the ReleaseVersion plugin.\nlet releaseVersion = "%s"\n' "$version" > "$2"
        """#
}
