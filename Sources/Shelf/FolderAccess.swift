import Darwin
import Foundation

/// Whether the app can actually list a folder, checked the way macOS privacy controls bite: opendir plus readdir.
enum FolderAccess: Equatable, Sendable {
    case granted(entries: Int)
    case denied(String)
    case missing

    static func check(_ folder: URL) -> FolderAccess {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return .missing }
        guard let dir = opendir(folder.path) else {
            let code = errno
            return .denied("opendir failed: errno \(code) \(String(cString: strerror(code)))")
        }
        defer { closedir(dir) }
        errno = 0
        var count = 0
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            if name != "." && name != ".." { count += 1 }
        }
        if errno != 0 {
            let code = errno
            return .denied("readdir failed: errno \(code) \(String(cString: strerror(code)))")
        }
        return .granted(entries: count)
    }
}
