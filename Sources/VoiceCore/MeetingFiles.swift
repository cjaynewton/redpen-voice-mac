import Foundation

/// Meeting-owned files are private before content is written and after replacement.
public enum MeetingFiles {
    /// Disks that keep owner-only permissions (APFS, Mac OS Extended). exFAT, FAT and network shares don't: there the
    /// permission is best effort and a meeting is still saved, as before (Nov 6 review); a symlink is refused anywhere.
    public static func keepsModes(_ url: URL) -> Bool {
        var path = url.path
        while !FileManager.default.fileExists(atPath: path), path != "/" { path = (path as NSString).deletingLastPathComponent }
        var s = statfs()
        guard statfs(path, &s) == 0 else { return true }
        let name = withUnsafeBytes(of: s.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ["apfs", "hfs"].contains(name)
    }

    public static func requireMode(_ mode: Int, at file: URL) throws {
        let a = try FileManager.default.attributesOfItem(atPath: file.path)
        guard a[.type] as? FileAttributeType != .typeSymbolicLink else { throw CocoaError(.fileWriteNoPermission) }
        guard (a[.posixPermissions] as? NSNumber)?.intValue == mode || !keepsModes(file) else { throw CocoaError(.fileWriteNoPermission) }
    }

    public static func setMode(_ mode: Int, at file: URL) throws {
        let a = try FileManager.default.attributesOfItem(atPath: file.path)
        guard a[.type] as? FileAttributeType != .typeSymbolicLink else { throw CocoaError(.fileWriteNoPermission) }
        do { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
        catch { if keepsModes(file) { throw error } }
        try requireMode(mode, at: file)
    }

    /// A user's existing destination folder is left as chosen. New folders are owner-only.
    public static func createFolder(_ folder: URL) throws {
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireMode(0o700, at: folder)
    }

    public static func scratch(in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(".redpen-meeting-" + UUID().uuidString, isDirectory: true)
        try createFolder(folder)
        return folder
    }

    /// Move a finished private file into place. Tighten existing metadata before replace can preserve it.
    public static func place(_ temp: URL, at file: URL) throws {
        let fm = FileManager.default
        try setMode(0o600, at: temp)
        if fm.fileExists(atPath: file.path) {
            try setMode(0o600, at: file)
            _ = try fm.replaceItemAt(file, withItemAt: temp)
        } else { try fm.moveItem(at: temp, to: file) }
        try setMode(0o600, at: file)
    }

    public static func save(_ data: Data, to file: URL) throws {
        let fm = FileManager.default
        let temp = file.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".tmp")
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? fm.removeItem(at: temp) }
        try requireMode(0o600, at: temp)
        let h = try FileHandle(forWritingTo: temp)
        do { try h.write(contentsOf: data); try h.close() }
        catch { try? h.close(); throw error }
        try place(temp, at: file)
    }
}
