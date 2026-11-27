import Foundation

/// Validates the non-query portion of an OAuth callback URL.
///
/// Providers that redirect straight back to the app must return the registered
/// custom URL exactly (scheme/host are case-insensitive; path is not). An empty
/// path and `/` are equivalent because OAuth servers may append a trailing slash
/// to redirect URIs without a path when returning query parameters. Providers
/// that use an HTTPS relay can only be checked against the custom scheme because
/// their registered HTTPS URL differs from the deep link emitted by the relay.
public enum OAuthCallbackURLMatcher {
    public static func matches(
        _ callbackURL: URL,
        registeredRedirectURI: String,
        callbackScheme: String
    ) -> Bool {
        guard
            let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let actualScheme = callback.scheme?.lowercased(),
            actualScheme == callbackScheme.lowercased(),
            let registered = URLComponents(string: registeredRedirectURI),
            let registeredScheme = registered.scheme?.lowercased(),
            callback.user == nil,
            callback.password == nil,
            registered.user == nil,
            registered.password == nil
        else {
            return false
        }

        // An HTTPS relay ultimately emits a different custom URL. Preserve the
        // existing scheme-only behavior for that flow.
        guard registeredScheme == callbackScheme.lowercased() else {
            return true
        }

        let registeredPath = registered.percentEncodedPath.isEmpty
            ? "/"
            : registered.percentEncodedPath
        let callbackPath = callback.percentEncodedPath.isEmpty
            ? "/"
            : callback.percentEncodedPath

        return registeredScheme == actualScheme
            && registered.host?.lowercased() == callback.host?.lowercased()
            && registered.port == callback.port
            && registeredPath == callbackPath
    }
}
