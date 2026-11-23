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

    public init(items: [FeedItem], state: SyncState, droppedOneTimeCodeCount: Int = 0) {
        self.items = items
        self.state = state
        self.droppedOneTimeCodeCount = droppedOneTimeCodeCount
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
    /// Lists matching message IDs across all pages, skips IDs already in `state`,
    /// fetches each unseen message, drops one-time-code messages before parsing,
    /// runs `NoticeFeed.process` on the remainder, and returns the new `FeedItem`s
    /// together with the updated `SyncState`. Email bodies are never stored.
    public static func sync(
        client: GmailClient,
        state: SyncState = SyncState(),
        lookbackDays: Int = 30,
        pageSize: Int? = nil,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> SyncResult {
        let query = buildQuery(lookbackDays: lookbackDays)
        var unseenIDs: [String] = []
        var queuedIDs = Set<String>()
        var pageToken: String? = nil
        var seenPageTokens = Set<String>()

        while true {
            try Task.checkCancellation()
            let page = try await client.listMessageIDs(
                query: query,
                maxResults: pageSize,
                pageToken: pageToken
            )
            for stub in page.messages {
                if state.seenMessageIDs.contains(stub.id) || queuedIDs.contains(stub.id) {
                    continue
                }
                queuedIDs.insert(stub.id)
                unseenIDs.append(stub.id)
            }
            guard let next = page.nextPageToken, !next.isEmpty, !seenPageTokens.contains(next) else {
                break
            }
            seenPageTokens.insert(next)
            pageToken = next
        }

        var updatedState = state
        var items: [FeedItem] = []
        var droppedCount = 0

        for id in unseenIDs {
            try Task.checkCancellation()
            let gmail = try await client.message(id: id)
            updatedState.seenMessageIDs.insert(id)

            if OneTimeCodeFilter.matches(gmail) {
                droppedCount += 1
                continue
            }

            items.append(NoticeFeed.process(gmail))
        }

        updatedState.lastSyncAt = now()
        return SyncResult(
            items: items,
            state: updatedState,
            droppedOneTimeCodeCount: droppedCount
        )
    }
}
