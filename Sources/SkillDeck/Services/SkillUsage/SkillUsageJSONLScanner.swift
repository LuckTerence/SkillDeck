import Darwin
import Foundation

/// Result of enumerating one provider's history directories.
struct SkillUsageLogEnumeration {
    let urls: [URL]
    let failedSourceCount: Int
    /// Directories whose contents may be incomplete. Cached files under them must be preserved
    /// because a missing URL cannot be distinguished from a file hidden by a read error.
    let failedDirectories: [URL]
}

/// Enumerates JSONL files and reports sources that exist but cannot be read.
///
/// A missing directory means the Agent is simply not installed, so it is not a failure.
/// An existing path that is not an enumerable directory, or an enumeration error, is a failure.
enum SkillUsageLogEnumerator {
    static func enumerate(
        directories: [URL],
        fileManager: FileManager
    ) -> SkillUsageLogEnumeration {
        var result: [URL] = []
        var failedSourceCount = 0
        var failedDirectories: [URL] = []

        for directory in directories {
            switch SkillUsagePathProbe.status(at: directory) {
            case .missing:
                // The Agent is simply not installed; this is not a read failure.
                continue
            case .notDirectory, .inaccessible:
                // Existing non-directory paths and permission errors both mean the configured
                // history root cannot be used, so they must be visible as failures.
                failedSourceCount += 1
                failedDirectories.append(directory)
                continue
            case .directory:
                break
            }

            var enumerationErrorCount = 0
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    enumerationErrorCount += 1
                    return true
                }
            ) else {
                failedSourceCount += 1
                failedDirectories.append(directory)
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                result.append(fileURL)
            }
            if enumerationErrorCount > 0 {
                failedSourceCount += enumerationErrorCount
                failedDirectories.append(directory)
            }
        }

        return SkillUsageLogEnumeration(
            urls: result.sorted { $0.path < $1.path },
            failedSourceCount: failedSourceCount,
            failedDirectories: failedDirectories
        )
    }
}

/// Canonical path used to relate cached files to a failed history directory.
///
/// `realpath` resolves `/var` to `/private/var`, matching the URLs returned by
/// `FileManager.enumerator`. When the final component cannot be read, resolve its parent
/// instead so a permission error does not prevent cache preservation.
private func canonicalUsagePath(_ url: URL) -> String {
    if let resolved = realpath(url.path, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
    }

    let parent = url.deletingLastPathComponent()
    if let resolvedParent = realpath(parent.path, nil) {
        defer { free(resolvedParent) }
        return URL(fileURLWithPath: String(cString: resolvedParent), isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
            .path
    }

    return url.standardizedFileURL.path
}

extension SkillUsageLogEnumeration {
    /// Cache entries belonging to directories whose enumeration failed.
    func cachedFilesToPreserve(from cache: SkillUsageLogCache) -> [String: SkillUsageCachedLog] {
        let prefixes = failedDirectories.map { directory -> String in
            let path = canonicalUsagePath(directory)
            return path.hasSuffix("/") ? path : path + "/"
        }
        guard !prefixes.isEmpty else { return [:] }

        var preserved: [String: SkillUsageCachedLog] = [:]
        for (path, cached) in cache.files {
            let fileURL = URL(fileURLWithPath: path)
            let candidates = [
                canonicalUsagePath(fileURL),
                fileURL.standardizedFileURL.path,
            ]
            if prefixes.contains(where: { prefix in
                candidates.contains { $0.hasPrefix(prefix) }
            }) {
                preserved[path] = cached
            }
        }
        return preserved
    }
}

/// Enumerates JSONL history files, reuses cached per-file results, and aggregates by skill ID.
struct SkillUsageJSONLScanner {
    let directories: [URL]
    let cacheURL: URL?
    let fileManager: FileManager
    let parse: @Sendable (String) -> [SkillUsageEvent]
    var parserVersion: Int = SkillUsageLogCache.currentParserVersion

    func scan() -> SkillUsageScanResult {
        var cache = SkillUsageLogCache.load(from: cacheURL)
        if cache.parserVersion != parserVersion {
            // The cached records were produced by older parsing rules, so reuse is unsafe.
            cache = SkillUsageLogCache(parserVersion: parserVersion)
        }
        var refreshedFiles: [String: SkillUsageCachedLog] = [:]
        var failedLogPaths: Set<String> = []
        var preservedLogPaths: Set<String> = []

        let enumeration = SkillUsageLogEnumerator.enumerate(
            directories: directories,
            fileManager: fileManager
        )
        for url in enumeration.urls {
            guard let fingerprint = fingerprint(for: url) else {
                failedLogPaths.insert(url.path)
                if let cached = cache.files[url.path] {
                    refreshedFiles[url.path] = cached
                    preservedLogPaths.insert(url.path)
                }
                continue
            }

            if let cached = cache.files[url.path], cached.fingerprint == fingerprint {
                refreshedFiles[url.path] = cached
                continue
            }

            var records: [String: MutableSkillUsageRecord] = [:]
            do {
                try SkillUsageLineReader.forEachLine(at: url) { line in
                    for event in parse(line) {
                        var record = records[event.skillID] ?? MutableSkillUsageRecord()
                        record.detectedInvocationCount += 1
                        if let timestamp = event.timestamp,
                           record.lastDetectedAt == nil || timestamp > record.lastDetectedAt! {
                            record.lastDetectedAt = timestamp
                        }
                        records[event.skillID] = record
                    }
                }
            } catch {
                failedLogPaths.insert(url.path)
                if let cached = cache.files[url.path] {
                    refreshedFiles[url.path] = cached
                    preservedLogPaths.insert(url.path)
                }
                continue
            }

            refreshedFiles[url.path] = SkillUsageCachedLog(
                fingerprint: fingerprint,
                records: records.mapValues {
                    SkillUsageRecord(
                        detectedInvocationCount: $0.detectedInvocationCount,
                        lastDetectedAt: $0.lastDetectedAt
                    )
                }
            )
        }

        // An enumeration error hides files, so their absence from `refreshedFiles` is not proof
        // that they were deleted. Keep the last known counts for the affected directories until
        // a later scan can enumerate them successfully.
        let preservedFiles = enumeration.cachedFilesToPreserve(from: cache)
        for (path, cached) in preservedFiles where refreshedFiles[path] == nil {
            refreshedFiles[path] = cached
            preservedLogPaths.insert(path)
        }

        cache.files = refreshedFiles
        cache.save(to: cacheURL, fileManager: fileManager)

        var merged: [String: MutableSkillUsageRecord] = [:]
        for file in refreshedFiles.values {
            for (skillID, record) in file.records {
                var aggregate = merged[skillID] ?? MutableSkillUsageRecord()
                aggregate.detectedInvocationCount += record.detectedInvocationCount
                if let timestamp = record.lastDetectedAt,
                   aggregate.lastDetectedAt == nil || timestamp > aggregate.lastDetectedAt! {
                    aggregate.lastDetectedAt = timestamp
                }
                merged[skillID] = aggregate
            }
        }

        return SkillUsageScanResult(
            records: merged.mapValues {
                SkillUsageRecord(
                    detectedInvocationCount: $0.detectedInvocationCount,
                    lastDetectedAt: $0.lastDetectedAt
                )
            },
            scannedLogCount: refreshedFiles.count,
            preservedLogCount: preservedLogPaths.count,
            failedLogCount: enumeration.failedSourceCount + failedLogPaths.count
        )
    }

    private func fingerprint(for url: URL) -> SkillUsageLogFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate else {
            return nil
        }
        return SkillUsageLogFingerprint(
            fileSize: UInt64(fileSize),
            modificationDate: modificationDate
        )
    }
}
