import Foundation

/// A message returned by the Gmail API (`users.messages.get` with `format=full`).
public struct GmailMessage: Codable, Equatable, Sendable {
    /// Gmail message identifier.
    public var id: String
    /// Gmail thread identifier, when present.
    public var threadId: String?
    /// Labels attached to the message.
    public var labelIds: [String]?
    /// Message creation timestamp as milliseconds since 1970, formatted as a string.
    public var internalDate: String?
    /// Root MIME payload of the message.
    public var payload: GmailPart?

    public init(
        id: String,
        threadId: String? = nil,
        labelIds: [String]? = nil,
        internalDate: String? = nil,
        payload: GmailPart? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
        self.internalDate = internalDate
        self.payload = payload
    }
}

/// A single MIME part within a Gmail message payload.
public struct GmailPart: Codable, Equatable, Sendable {
    /// Gmail-assigned part identifier, when present.
    public var partId: String?
    /// MIME type of this part, such as `text/plain` or `multipart/signed`.
    public var mimeType: String?
    /// Attachment filename, if this part represents a file.
    public var filename: String?
    /// Headers scoped to this MIME part.
    public var headers: [GmailHeader]?
    /// Body data or attachment reference for this part.
    public var body: GmailBody?
    /// Nested child parts for multipart containers.
    public var parts: [GmailPart]?

    public init(
        partId: String? = nil,
        mimeType: String? = nil,
        filename: String? = nil,
        headers: [GmailHeader]? = nil,
        body: GmailBody? = nil,
        parts: [GmailPart]? = nil
    ) {
        self.partId = partId
        self.mimeType = mimeType
        self.filename = filename
        self.headers = headers
        self.body = body
        self.parts = parts
    }
}

/// A single raw header entry from a Gmail payload.
public struct GmailHeader: Codable, Equatable, Sendable {
    /// Header field name as returned by Gmail.
    public var name: String
    /// Header field value as returned by Gmail.
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The body payload of a Gmail MIME part.
public struct GmailBody: Codable, Equatable, Sendable {
    /// Size of the body in bytes.
    public var size: Int?
    /// Base64url-encoded body bytes, omitted for attachments and empty containers.
    public var data: String?
    /// Identifier used to fetch an attachment separately, when present.
    public var attachmentId: String?

    public init(
        size: Int? = nil,
        data: String? = nil,
        attachmentId: String? = nil
    ) {
        self.size = size
        self.data = data
        self.attachmentId = attachmentId
    }
}
