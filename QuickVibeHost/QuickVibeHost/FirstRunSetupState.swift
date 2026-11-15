import Foundation

@MainActor
enum FirstRunSetupState {
    static let hasCompletedKey = "hasCompletedFirstRunSetup"
    static let hasSkippedKey = "hasSkippedFirstRunSetup"

    static func isComplete(
        accessibilityGranted: Bool,
        asrConfigured: Bool
    ) -> Bool {
        accessibilityGranted && asrConfigured
    }

    static func shouldShowSetup(
        defaults: UserDefaults = .standard,
        localASRAvailable: Bool
    ) -> Bool {
        if defaults.bool(forKey: hasSkippedKey) { return false }
        if let completed = defaults.object(forKey: hasCompletedKey) as? Bool {
            return !completed
        }
        if hasLegacySetupTrace(defaults: defaults, localASRAvailable: localASRAvailable) {
            defaults.set(true, forKey: hasCompletedKey)
            return false
        }
        return true
    }

    static func hasLegacySetupTrace(
        defaults: UserDefaults = .standard,
        localASRAvailable: Bool
    ) -> Bool {
        let doubaoAppKey = defaults.string(forKey: "doubaoAppKey") ?? ""
        let doubaoAccessKey = defaults.string(forKey: "doubaoAccessKey") ?? ""
        let lastConnectedBLEDeviceUUID = defaults.string(forKey: "lastConnectedBLEDeviceUUID") ?? ""
        return (!doubaoAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !doubaoAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
            !lastConnectedBLEDeviceUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            localASRAvailable ||
            hasLocalASRAvailableTrace()
    }

    static func hasLocalASRAvailableTrace(fileManager: FileManager = .default) -> Bool {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuickVibeHost/models", isDirectory: true)
        let cached = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: cached),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data),
              manifest.version == ASRModelManager.expectedModelVersion else {
            return false
        }
        let dir = root.appendingPathComponent(manifest.version, isDirectory: true)
        return manifest.files.allSatisfy { spec in
            fileManager.fileExists(atPath: dir.appendingPathComponent(spec.name).path)
        }
    }

    static var accessibilityGranted: Bool {
        KeyboardSimulator.hasAccessibilityPermission
    }
}
