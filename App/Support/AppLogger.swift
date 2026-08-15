import os

enum AppLogger {
    static let launcher = Logger(
        subsystem: "com.harness.desktop.launcher",
        category: "launcher"
    )
    static let runtime = Logger(
        subsystem: "com.harness.desktop.launcher",
        category: "runtime"
    )
    static let plugins = Logger(
        subsystem: "com.harness.desktop.launcher",
        category: "plugins"
    )
}
