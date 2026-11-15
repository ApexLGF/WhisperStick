import Foundation
import os

enum PTYWriter {
    private static let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "PTYWriter")

    /// Write text to a TTY device (e.g., /dev/ttys004).
    /// Returns true if the write succeeded.
    @discardableResult
    static func write(to tty: String, text: String) -> Bool {
        let devPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        guard let data = text.data(using: .utf8) else {
            logger.warning("Failed to encode text as UTF-8")
            return false
        }

        let fd = open(devPath, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else {
            logger.warning("Failed to open \(devPath, privacy: .public): errno=\(errno)")
            return false
        }
        defer { close(fd) }

        let result = data.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return -1 }
            return Foundation.write(fd, base, data.count)
        }

        if result == data.count {
            logger.info("Wrote \(data.count) bytes to \(devPath, privacy: .public)")
            return true
        } else {
            logger.warning("Partial write to \(devPath, privacy: .public): \(result)/\(data.count)")
            return false
        }
    }

    /// Safely inject a slash command (e.g., "/color red") into a Claude Code terminal.
    /// Only call this when the session is in waitingForInput phase.
    static func injectSlashCommand(_ command: String, tty: String) {
        let fullCommand = command.hasSuffix("\n") ? command : command + "\n"
        if write(to: tty, text: fullCommand) {
            logger.info("Injected command: \(command, privacy: .public) to \(tty, privacy: .public)")
        }
    }
}
