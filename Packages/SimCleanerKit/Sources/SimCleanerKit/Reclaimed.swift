//
//  Reclaimed.swift
//  SimCleanerKit
//

import Foundation

/// How much space a cleanup gave back, judged by what is on disk right before it and right after it rather
/// than by whether the operation reported success.
///
/// It's an estimate. Each item counts the bytes it held alone (`DiskFootprint.exclusiveBytes`), so blocks an
/// APFS clone shares with files elsewhere aren't counted; where APFS can't say, a file counts its whole size
/// on disk. A local Time Machine snapshot can also keep deleted files on disk for a while.
public enum Reclaimed {
    /// What `url` holds right now, or nil when nothing is there. Taken right before a cleanup, so the credit
    /// comes from the disk as it is, not from a list that another window may already have acted on.
    public static func measure(_ url: URL) async -> DiskFootprint? {
        await Task.detached(priority: .userInitiated) {
            DiskUsage.isGone(url) ? nil : DiskUsage.measure(url)
        }.value
    }

    /// All of `before` when nothing is at `url` any more, otherwise nothing.
    public static func ifGone(_ url: URL, _ before: DiskFootprint) -> Int64 {
        DiskUsage.isGone(url) ? before.exclusiveBytes : 0
    }

    /// Erasing keeps the simulator's folder, so this is what it held right before the erase minus everything
    /// it holds now. Erasing an already empty simulator gives back nothing.
    public static func byErasing(_ folder: URL, before: DiskFootprint, erased: Bool) async -> Int64 {
        guard erased, let after = await measure(folder) else { return 0 }
        return max(before.exclusiveBytes - after.allocatedBytes, 0)
    }
}
