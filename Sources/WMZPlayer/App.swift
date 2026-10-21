import AppKit

@main
struct WMZPlayerApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Headless runs must not appear in the Dock or take focus.
        let headless = CommandLine.arguments.contains("--headless")
        application.setActivationPolicy(headless ? .accessory : .regular)
        application.run()
    }
}
