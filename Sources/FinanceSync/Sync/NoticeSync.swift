import FinanceCore
import Foundation

/// Persisted incremental sync cursor containing only seen Gmail message IDs and
/// the last sync timestamp. Never stores email subjects or bodies.
public struct SyncState: Codable, Equatable, Sendable {
    /// Gmail message IDs already processed or dropped in earlier syncs.
    public var seenMessageIDs: Set<String>
    /// Timestamp of the most recent completed sync, if any.
    public var lastSyncAt: Date?

    public init(seenMessageIDs: Set<String> = [], lastSyncAt: Date? = nil) {
        self.seenMessageIDs = seenMessageIDs
        self.lastSyncAt = lastSyncAt
    }
}

/// One incremental batch committed during `NoticeSync.sync`.
public struct SyncBatch: Equatable, Sendable {
    /// Feed outcomes for newly fetched messages in this batch (excluding dropped one-time codes).
    public var items: [FeedItem]
    /// Gmail message IDs processed in this batch (including dropped one-time codes).
    public var seenMessageIDs: [String]
    /// Cumulative sync state after this batch.
    public var state: SyncState
    /// Number of one-time-code messages dropped in this batch.
    public var droppedOneTimeCodeCount: Int

    public init(
        items: [FeedItem],
        seenMessageIDs: [String],
        state: SyncState,
        droppedOneTimeCodeCount: Int = 0
    ) {
        self.items = items
        self.seenMessageIDs = seenMessageIDs
        self.state = state
        self.droppedOneTimeCodeCount = droppedOneTimeCodeCount
    }
}

/// Output of one incremental `NoticeSync.sync` run.
///
/// Holds only parsed feed outcomes, the updated `SyncState`, and a count of
/// dropped one-time-code messages. Never stores email bodies.
public struct SyncResult: Equatable, Sendable {
    /// Feed outcomes for newly fetched messages that were not dropped as one-time codes.
    public var items: [FeedItem]
    /// Updated sync state including newly seen message IDs and the sync timestamp.
    public var state: SyncState
    /// Number of newly fetched messages dropped before parsing because they matched
    /// one-time-code wording.
    public var droppedOneTimeCodeCount: Int
    /// True when the run stopped early because `deadline` was reached before all pages finished.
    public var reachedDeadline: Bool

    public init(
        items: [FeedItem],
        state: SyncState,
        droppedOneTimeCodeCount: Int = 0,
        reachedDeadline: Bool = false
    ) {
        self.items = items
        self.state = state
        self.droppedOneTimeCodeCount = droppedOneTimeCodeCount
        self.reachedDeadline = reachedDeadline
    }
}

/// Identifies one-time-code and verification emails so they can be discarded
/// before parsing and never retained.
public enum OneTimeCodeFilter {
    /// Exact wording matched against decoded email subjects and bodies.
    public static let terms: [String] = [
        "認証コード",
        "ワンタイム",
        "確認コード",
        "認証番号",
        "パスコード",
        "本人確認",
        "セキュリティコード",
        "verification code",
    ]

    private static let foldedJapaneseTerms: [String] = [
        "認証コード",
        "ワンタイム",
        "確認コード",
        "認証番号",
        "パスコード",
        "本人確認",
        "セキュリティコード",
    ].map(TextFold.key)

    private static let asciiPhrase = "verification code"

    /// Returns `true` if `subject` or `text` contains any one-time-code term.
    public static func matches(subject: String, text: String?) -> Bool {
        if matchesString(subject) {
            return true
        }
        if let text, matchesString(text) {
            return true
        }
        return false
    }

    /// Returns `true` if the decoded subject, plain-text body, or HTML body of
    /// `gmail` matches any one-time-code term.
    public static func matches(_ gmail: GmailMessage) -> Bool {
        let mail = MailMessage(gmail: gmail)
        if matchesString(mail.subject) {
            return true
        }
        if let textBody = mail.textBody, matchesString(textBody) {
            return true
        }
        if let htmlBody = mail.htmlBody, matchesString(HTMLText.plainText(htmlBody)) {
            return true
        }
        return false
    }

    private static func matchesString(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let folded = TextFold.key(value)
        for term in foldedJapaneseTerms where folded.contains(term) {
            return true
        }
        let normalizedASCII = normalizeWhitespaceASCII(value)
        return normalizedASCII.contains(asciiPhrase)
    }

    private static func normalizeWhitespaceASCII(_ value: String) -> String {
        let folded = value
            .precomposedStringWithCompatibilityMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !out.isEmpty {
                    pendingSpace = true
                }
            } else {
                if pendingSpace {
                    out.append(" ")
                    pendingSpace = false
                }
                out.append(scalar)
            }
        }
        return String(out)
    }
}

/// Runs an incremental Gmail sync and converts new bank/card emails into `FeedItem`s.
public enum NoticeSync {
    /// Subject exclusions included in the Gmail search query.
    public static let excludedSubjectTerms: [String] = [
        "認証コード",
        "ワンタイムパスワード",
        "確認コード",
        "認証番号",
        "パスコード",
        "本人確認",
    ]

    /// Builds the Gmail search query for all known `NoticeFeed.senders` over the
    /// last `lookbackDays` days while excluding common one-time-code subjects.
    public static func buildQuery(lookbackDays: Int = 30) -> String {
        let days = max(1, lookbackDays)
        let senders = NoticeFeed.senders.keys.sorted().joined(separator: " OR ")
        let exclusions = excludedSubjectTerms.joined(separator: " OR ")
        return "from:(\(senders)) newer_than:\(days)d -subject:(\(exclusions))"
    }

    /// Performs one incremental sync against `client`.
    ///
    /// Processes Gmail list pages newest-first, fetches unseen messages in batches
    /// of `batchSize`, drops one-time-code messages before parsing, and invokes
    /// `onBatch` after each batch so callers can commit progress incrementally.
    /// When `deadline` is reached, stops cleanly with `reachedDeadline == true`
    /// while preserving previously committed `seenMessageIDs` so the next run continues.
    /// Email bodies are never stored.
    public static func sync(
        client: GmailClient,
        state: SyncState = SyncState(),
        lookbackDays: Int = 30,
        pageSize: Int? = nil,
        batchSize: Int? = nil,
        deadline: Date? = nil,
        now: @Sendable () -> Date = { Date() },
        onBatch: (@Sendable (SyncBatch) async throws -> Void)? = nil
    ) async throws -> SyncResult {
        let query = buildQuery(lookbackDays: lookbackDays)
        let effectiveBatchSize = batchSize.map { max(1, $0) }
        var updatedState = state
        var allItems: [FeedItem] = []
        var totalDropped = 0
        var pageToken: String? = nil
        var seenPageTokens = Set<String>()
        var reachedDeadline = false

        var batchItems: [FeedItem] = []
        var batchSeenIDs: [String] = []
        var batchDropped = 0

        func flushBatch() async throws {
            guard !batchSeenIDs.isEmpty else { return }
            let batch = SyncBatch(
                items: batchItems,
                seenMessageIDs: batchSeenIDs,
                state: updatedState,
                droppedOneTimeCodeCount: batchDropped
            )
            batchItems.removeAll(keepingCapacity: true)
            batchSeenIDs.removeAll(keepingCapacity: true)
            batchDropped = 0
            try await onBatch?(batch)
        }

        while true {
            try Task.checkCancellation()
            if let deadline, now() >= deadline {
                reachedDeadline = true
                break
            }

            let page = try await client.listMessageIDs(
                query: query,
                maxResults: pageSize,
                pageToken: pageToken
            )

            var pageUnseen: [String] = []
            var queuedInPage = Set<String>()
            for stub in page.messages {
                if updatedState.seenMessageIDs.contains(stub.id) || queuedInPage.contains(stub.id) {
                    continue
                }
                queuedInPage.insert(stub.id)
                pageUnseen.append(stub.id)
            }

            for id in pageUnseen {
                if Task.isCancelled {
                    try? await flushBatch()
                    throw CancellationError()
                }
                if let deadline, now() >= deadline {
                    try await flushBatch()
                    reachedDeadline = true
                    break
                }

                let gmail: GmailMessage
                do {
                    gmail = try await client.message(id: id)
                } catch {
                    if !batchSeenIDs.isEmpty {
                        try? await flushBatch()
                    }
                    throw error
                }

                updatedState.seenMessageIDs.insert(id)
                batchSeenIDs.append(id)

                if OneTimeCodeFilter.matches(gmail) {
                    batchDropped += 1
                    totalDropped += 1
                } else {
                    let item = NoticeFeed.process(gmail)
                    batchItems.append(item)
                    allItems.append(item)
                }

                if let limit = effectiveBatchSize, batchSeenIDs.count >= limit {
                    try await flushBatch()
                }
            }

            try await flushBatch()
            if reachedDeadline {
                break
            }

            guard let next = page.nextPageToken, !next.isEmpty, !seenPageTokens.contains(next) else {
                break
            }
            seenPageTokens.insert(next)
            pageToken = next
        }

        if !reachedDeadline {
            updatedState.lastSyncAt = now()
        }
        return SyncResult(
            items: allItems,
            state: updatedState,
            droppedOneTimeCodeCount: totalDropped,
            reachedDeadline: reachedDeadline
        )
    }
}
