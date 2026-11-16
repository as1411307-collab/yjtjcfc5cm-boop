import Foundation
import Security
import LocalAuthentication

enum SecretStore {
    static let account = "personal-api-key"
    static let service = "UnifiedAI"

    static func save(_ value: String) -> Bool {
        let bytes = Data(value.utf8)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                       kSecAttrAccount: account] as CFDictionary)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: bytes,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                       kSecAttrAccount: account] as CFDictionary)
    }
}

enum DeviceLock {
    /// Human-readable reason device authentication cannot run, nil when it can.
    /// The lock screen must explain itself instead of failing silently.
    static func unavailabilityReason() -> String? {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return nil }
        return "المصادقة البيومترية غير متاحة على هذا الجهاز"
    }

    static func authenticate() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: "فتح مساعدك الشخصي") { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
