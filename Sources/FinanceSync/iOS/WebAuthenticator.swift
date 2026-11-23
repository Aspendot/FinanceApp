#if canImport(AuthenticationServices) && os(iOS)
import AuthenticationServices
import Foundation
import UIKit

/// Errors thrown by `WebAuthenticator`.
public enum WebAuthenticatorError: Error, LocalizedError, Equatable, Sendable {
    /// The user dismissed the sign-in sheet before completing authentication.
    case cancelled
    /// `ASWebAuthenticationSession.start()` returned `false`.
    case failedToStart
    /// The authentication session completed without providing a callback URL.
    case missingCallbackURL
    /// The authentication session failed with an underlying system error.
    case sessionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Google sign-in was cancelled."
        case .failedToStart:
            return "Could not open the Google sign-in sheet."
        case .missingCallbackURL:
            return "Google sign-in finished without a callback URL."
        case .sessionFailed(let message):
            return "Google sign-in failed: \(message)"
        }
    }
}

/// Async wrapper around `ASWebAuthenticationSession` for iOS OAuth sign-in.
///
/// Sets `prefersEphemeralWebBrowserSession = false` so the user can reuse
/// an existing Google sign-in session on the device.
@MainActor
public final class WebAuthenticator {
    private let anchorProvider: @MainActor () -> ASPresentationAnchor
    private var activeSession: ASWebAuthenticationSession?
    private var activeContextProvider: PresentationContextProvider?

    /// Creates a web authenticator with an optional presentation anchor provider.
    public init(anchorProvider: (@MainActor () -> ASPresentationAnchor)? = nil) {
        self.anchorProvider = anchorProvider ?? { Self.defaultPresentationAnchor() }
    }

    /// Presents `authURL` in an `ASWebAuthenticationSession` and returns the
    /// redirect callback URL matching `callbackScheme`.
    public func authenticate(
        authURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        if Task.isCancelled {
            throw WebAuthenticatorError.cancelled
        }
        let contextProvider = PresentationContextProvider(anchorProvider: anchorProvider)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: callbackScheme
                ) { [weak self] callbackURL, error in
                    Task { @MainActor [weak self] in
                        self?.activeSession = nil
                        self?.activeContextProvider = nil

                        if let error {
                            if let authError = error as? ASWebAuthenticationSessionError,
                               authError.code == .canceledLogin
                            {
                                continuation.resume(throwing: WebAuthenticatorError.cancelled)
                            } else {
                                continuation.resume(
                                    throwing: WebAuthenticatorError.sessionFailed(error.localizedDescription)
                                )
                            }
                            return
                        }

                        guard let callbackURL else {
                            continuation.resume(throwing: WebAuthenticatorError.missingCallbackURL)
                            return
                        }
                        continuation.resume(returning: callbackURL)
                    }
                }

                session.prefersEphemeralWebBrowserSession = false
                session.presentationContextProvider = contextProvider

                self.activeSession = session
                self.activeContextProvider = contextProvider

                if !session.start() {
                    self.activeSession = nil
                    self.activeContextProvider = nil
                    continuation.resume(throwing: WebAuthenticatorError.failedToStart)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.activeSession?.cancel()
            }
        }
    }

    private static func defaultPresentationAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }
        if let firstWindow = scenes.flatMap(\.windows).first {
            return firstWindow
        }
        if let firstScene = scenes.first {
            return ASPresentationAnchor(windowScene: firstScene)
        }
        return ASPresentationAnchor(frame: .zero)
    }
}

@MainActor
private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchorProvider: @MainActor () -> ASPresentationAnchor

    init(anchorProvider: @escaping @MainActor () -> ASPresentationAnchor) {
        self.anchorProvider = anchorProvider
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchorProvider()
    }
}
#endif
