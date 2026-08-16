import AppKit

if let code = CommandLineMode.run(Array(CommandLine.arguments.dropFirst())) {
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
