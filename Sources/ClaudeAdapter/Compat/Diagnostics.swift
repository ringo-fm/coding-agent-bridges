import Logging

final class Diagnostics: Sendable {
    let logger: Logger
    let debug: Bool

    init(logger: Logger, debug: Bool) {
        self.logger = logger
        self.debug = debug
    }

    func ignoredField(_ field: String, detail: String = "") {
        guard debug else { return }
        if detail.isEmpty {
            logger.debug("ignored field: \(field)")
        } else {
            logger.debug("ignored field: \(field) \(detail)")
        }
    }

    func unsupportedBlock(_ type: String, in role: String) {
        logger.warning("unsupported content block type '\(type)' in \(role) role; rendered as text marker or skipped")
    }

    func note(_ message: String) {
        logger.info("\(message)")
    }
}

