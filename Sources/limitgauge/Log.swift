import os

enum Log {
    static let subsystem = "io.github.eladefrati.limitgauge"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let fetch = Logger(subsystem: subsystem, category: "fetch")
}
