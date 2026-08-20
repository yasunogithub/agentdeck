import Foundation

/// Guards TCC-protected folders (~/Desktop, ~/Documents, ~/Downloads).
/// Spawning a process whose cwd is inside one of them triggers the macOS
/// permission prompt ("would like to access files in your Downloads folder").
/// Sessions whose transcripts record such cwds would otherwise spam that
/// dialog; falling back to the home directory keeps things working silently.
enum SafeCwd {
    static func resolve(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for name in ["Desktop", "Documents", "Downloads"] {
            let protected = home + "/" + name
            if cwd == protected || cwd.hasPrefix(protected + "/") {
                return home
            }
        }
        return cwd
    }
}
