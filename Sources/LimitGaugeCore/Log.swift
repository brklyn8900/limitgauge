import os

/// One subsystem for both targets. `package`: the app target sees it, nothing outside this
/// package does.
package enum Log {
    package static let subsystem = "io.github.eladefrati.limitgauge"
    package static let app = Logger(subsystem: subsystem, category: "app")
    package static let fetch = Logger(subsystem: subsystem, category: "fetch")
    package static let poll = Logger(subsystem: subsystem, category: "poll")
}
