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
    private struct Attempt {
        let id: UUID
        let session: ASWebAuthenticationSession
        let contextProvider: PresentationContextProvider
        let continuation: CheckedContinuation<URL, any Error>
    }

    private var activeAttempt: Attempt?

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
        guard activeAttempt == nil else { throw WebAuthenticatorError.failedToStart }
        let id = UUID()
        let contextProvider = PresentationContextProvider(anchorProvider: anchorProvider)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: WebAuthenticatorError.cancelled)
                    return
                }

                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: callbackScheme
                ) { @Sendable [weak self] callbackURL, error in
                    Task { @MainActor in
                        if let error {
                            let problem: WebAuthenticatorError
                            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                                problem = .cancelled
                            } else {
                                problem = .sessionFailed(error.localizedDescription)
                            }
                            self?.finish(id, with: .failure(problem))
                        } else if let callbackURL {
                            self?.finish(id, with: .success(callbackURL))
                        } else {
                            self?.finish(id, with: .failure(WebAuthenticatorError.missingCallbackURL))
                        }
                    }
                }

                session.prefersEphemeralWebBrowserSession = false
                session.presentationContextProvider = contextProvider
                activeAttempt = Attempt(id: id, session: session, contextProvider: contextProvider, continuation: continuation)

                if !session.start() {
                    finish(id, with: .failure(WebAuthenticatorError.failedToStart))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id)
            }
        }
    }

    private func finish(_ id: UUID, with result: Result<URL, any Error>) {
        guard let attempt = activeAttempt, attempt.id == id else { return }
        activeAttempt = nil
        attempt.continuation.resume(with: result)
    }

    private func cancel(_ id: UUID) {
        guard let attempt = activeAttempt, attempt.id == id else { return }
        attempt.session.cancel()
        finish(id, with: .failure(WebAuthenticatorError.cancelled))
    }

    private static func defaultPresentationAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
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
