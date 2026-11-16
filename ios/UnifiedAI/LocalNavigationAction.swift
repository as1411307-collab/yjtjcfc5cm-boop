import Foundation

enum LocalNavigationAction: Equatable {
    case tasks, incompleteTasks, sessions, memories, settings

    var description: String {
        switch self {
        case .tasks: return "فتح لوحة المهام وعرض جميع المهام"
        case .incompleteTasks: return "فتح لوحة المهام وتصفية المهام غير المنجزة"
        case .sessions: return "فتح قائمة المحادثات"
        case .memories: return "فتح الذاكرة الشخصية"
        case .settings: return "فتح الإعدادات"
        }
    }

    static func parse(_ raw: String) -> Self? {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "أ", with: "ا")
            .replacingOccurrences(of: "إ", with: "ا")
            .replacingOccurrences(of: "آ", with: "ا")
        switch command {
        case "افتح المهام", "اعرض المهام", "لوحة المهام", "open tasks":
            return .tasks
        case "اعرض المهام غير المنجزة", "افتح المهام غير المنجزة", "show incomplete tasks":
            return .incompleteTasks
        case "افتح المحادثات", "اعرض المحادثات", "open sessions":
            return .sessions
        case "افتح الذاكرة", "اعرض الذاكرة", "open memories":
            return .memories
        case "افتح الاعدادات", "الاعدادات", "open settings":
            return .settings
        default:
            return nil
        }
    }
}
