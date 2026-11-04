import Foundation
import os

/// Journal unifié : `Journal.app.info("…")`, visible dans Console.app, filtré par sous-système = bundle ID.
public enum Journal {
    public static let app = Logger(subsystem: Bundle.main.bundleIdentifier ?? "fr.anthony.socle", category: "app")
}
