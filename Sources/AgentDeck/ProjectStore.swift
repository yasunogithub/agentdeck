import Foundation

/// User-managed projects: folders the deck can open a fresh terminal in,
/// plus projects hidden from the sidebar's derived list. Persisted in
/// UserDefaults — derived, resettable, rot-proof.
final class ProjectStore: ObservableObject, @unchecked Sendable {
    static let shared = ProjectStore()

    @Published private(set) var manual: [(name: String, path: String)] = []
    @Published private(set) var hidden: Set<String> = []

    private let manualKey = "projects.manual"
    private let hiddenKey = "projects.hidden"

    init() {
        let d = UserDefaults.standard
        if let arr = d.array(forKey: manualKey) as? [[String: String]] {
            manual = arr.compactMap { e in
                guard let n = e["name"], let p = e["path"] else { return nil }
                return (n, p)
            }
        }
        if let arr = d.stringArray(forKey: hiddenKey) {
            hidden = Set(arr)
        }
    }

    func add(name: String, path: String) {
        manual.append((name, path))
        save()
    }

    func removeManual(_ name: String) {
        manual.removeAll { $0.name == name }
        save()
    }

    func hide(_ project: String) {
        hidden.insert(project)
        save()
    }

    func unhide(_ project: String) {
        hidden.remove(project)
        save()
    }

    func path(for project: String) -> String? {
        manual.first { $0.name == project }?.path
    }

    private func save() {
        UserDefaults.standard.set(manual.map { ["name": $0.name, "path": $0.path] }, forKey: manualKey)
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey)
    }
}
