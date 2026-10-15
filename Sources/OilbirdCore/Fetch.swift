import CryptoKit
import Foundation
import OilbirdModel

/// Admits only bytes that match their digest.
///
/// Resumable, because first run moves 1.14 GiB and a laptop that slept
/// mid-download is the likeliest reason a first run never completes. Fails
/// **closed**: a mismatch discards rather than caches, because a corrupt
/// artefact that survives fails later and far less legibly.
public enum Fetch {
    /// Where a partial download lives, keyed by digest rather than by URL or
    /// version — a changed artefact under a fixed version must be a miss, not
    /// a silent overwrite.
    static func partial(for sha256: String) -> URL {
        Paths.Cache.partials.appending(path: sha256)
    }

    public struct Report: Sendable {
        public let bytes: Int64
        public let resumedFrom: Int64
    }

    /// Downloads to the partials directory and verifies. Returns the verified
    /// file, which the caller then places (`Install`).
    public static func artifact(
        url: URL, expecting sha256: String, bytes expected: Int64,
        progress: @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        let destination = partial(for: sha256)
        try FileManager.default.createDirectory(
            at: Paths.Cache.partials, withIntermediateDirectories: true)

        let already = existingBytes(at: destination)
        if already == expected, try digest(of: destination) == sha256 {
            Log.info("cached \(url.lastPathComponent) — digest matches, not re-downloading")
            return destination
        }

        Log.phase("download \(url.lastPathComponent)")
        var request = URLRequest(url: url)
        if already > 0 && already < expected {
            request.setValue("bytes=\(already)-", forHTTPHeaderField: "Range")
            Log.info("resuming at \(already) of \(expected) bytes")
        }

        try await transfer(request, to: destination, from: already, of: expected, progress: progress)

        let actual = try digest(of: destination)
        guard actual == sha256 else {
            // Fail closed. Discarding is the point: a corrupt file left in the
            // cache would be "resumed" forever.
            try? FileManager.default.removeItem(at: destination)
            throw OilbirdError(
                .checksumMismatch,
                "Downloaded data was corrupt.",
                recovery: .retry("Download again"),
                underlying: "expected \(sha256), got \(actual) for \(url.absoluteString)")
        }
        return destination
    }

    // MARK: -

    private static func transfer(
        _ request: URLRequest, to destination: URL, from already: Int64, of expected: Int64,
        progress: @Sendable (Int64, Int64) -> Void
    ) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await HTTP.session.bytes(for: request)
        } catch {
            // ⚠ The FIRST failure a machine with no network reaches, and it
            // left raw: `NSURLErrorDomain Code=-1004`, no sentence and no
            // recovery. Only the drop DURING a transfer was ever wrapped.
            throw OilbirdError(
                .offline, unreachable(error), recovery: .retry("Retry"),
                underlying: "\(error) reaching \(request.url?.absoluteString ?? "?")")
        }
        guard let http = response as? HTTPURLResponse else {
            throw OilbirdError(
                .offline, "No connection.", recovery: .retry("Retry"),
                underlying: "no HTTP response for \(request.url?.absoluteString ?? "?")")
        }
        // 206 means the range was honoured; 200 means the server ignored it and
        // is sending the whole body, so the partial must be discarded.
        let appending = http.statusCode == 206 && already > 0
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw OilbirdError(
                http.statusCode == 404 ? .originMoved : .offline,
                http.statusCode == 404
                    ? "That download is no longer where it used to be."
                    : "The download could not be started.",
                recovery: .retry("Retry"),
                underlying: "HTTP \(http.statusCode) for \(request.url?.absoluteString ?? "?")")
        }
        // ⚠ Only when starting over. `createFile` TRUNCATES an existing file
        // to the contents given — nil, meaning empty — so on the resume path
        // it emptied the partial and `seekToEnd` then seeked to zero.
        if !appending {
            try? FileManager.default.removeItem(at: destination)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        if appending { try handle.seekToEnd() }

        var written = appending ? already : 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)

        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            progress(written, expected)
        }

        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 { try flush() }
            }
        } catch {
            // ⚠ What arrived is KEPT, which is the whole of `truncate`. A
            // drop before the first mebibyte used to discard the transfer
            // entirely, leaving the resume nothing to resume from.
            try? flush()
            // ⚠ And it leaves as an OilbirdError. A dropped download used to
            // reach a person as `NSURLErrorDomain Code=-1005` with no
            // recovery, on the failure a 1.14 GiB first run most often hits.
            throw OilbirdError(
                .offline, "The download stopped before it finished.",
                recovery: .retry("Resume the download"),
                underlying: "\(error) after \(written) of \(expected) bytes")
        }
        try flush()
    }

    /// One sentence for the reader, chosen by why the connection failed.
    ///
    /// Four outcomes and not one, because the action differs: a Mac with no
    /// network, a name that will not resolve and a host that refuses are
    /// three different things to go and look at.
    private static func unreachable(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet:
            "This Mac is not connected to the internet."
        case .cannotFindHost, .dnsLookupFailed:
            "That download's address could not be looked up."
        case .timedOut:
            "The download did not answer in time."
        default:
            "Oilbird could not reach the download."
        }
    }

    private static func existingBytes(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
