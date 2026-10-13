//
//  DiskUsage.swift
//  SimCleanerKit
//

import Darwin
import Foundation

/// Measures file trees the way APFS stores them.
///
/// Simulators are full of APFS clones: `simctl install` and `simctl clone` copy files without copying
/// their blocks. Adding up allocated sizes counts every clone in full, so a cleaner that does that
/// promises more space than deleting will free. Here every file contributes its allocated size and its
/// private size (`ATTR_CMNEXT_PRIVATESIZE`, the bytes that would be freed if only that file were deleted).
public enum DiskUsage {
    /// Walks `url` without following symlinks or crossing into other volumes, so a mounted file
    /// system inside the tree (like Device Hub's DeviceFS) is never counted or entered.
    public static func measure(_ url: URL) -> DiskFootprint {
        let path = url.path
        guard let cPath = strdup(path) else { return .zero }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return .zero }
        defer { fts_close(stream) }

        var footprint = DiskFootprint.zero
        while let entry = fts_read(stream) {
            guard Int32(entry.pointee.fts_info) == FTS_F, let stat = entry.pointee.fts_statp else { continue }
            let allocated = Int64(stat.pointee.st_blocks) * 512
            footprint.allocatedBytes += allocated
            // Volumes that don't report private sizes (not APFS) share nothing, so everything is exclusive.
            footprint.exclusiveBytes += privateSize(atPath: entry.pointee.fts_path) ?? allocated
        }
        return footprint
    }

    /// Bytes of the file at `path` that no other file shares, or nil when the volume can't tell.
    public static func privateSize(atPath path: UnsafePointer<CChar>) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)

        // Layout: u_int32_t length, attribute_set_t returned (5 × u_int32_t), off_t private size.
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> Int64? in
            let returnedForkAttributes = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            guard returnedForkAttributes & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 24, as: Int64.self)
        }
    }

    public static func privateSize(of url: URL) -> Int64? {
        url.path.withCString { privateSize(atPath: $0) }
    }

    /// True only when nothing is at `url` any more. A folder SimCleaner merely can't see (no permission,
    /// a sandbox) isn't gone, so space is never counted as freed on a guess.
    public static func isGone(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return false }
        return errno == ENOENT
    }

    /// The file system that holds `url`, so tree walks can stay on it.
    public static func deviceID(of url: URL) -> dev_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_dev
    }
}
