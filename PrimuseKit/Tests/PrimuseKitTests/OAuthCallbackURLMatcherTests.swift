import Foundation
import Testing
@testable import PrimuseKit

private let pan123RedirectURI = "primuse://oauth/123pan/callback"

@Test func oauthCallbackAcceptsRegisteredPan123URLWithQuery() {
    let callback = URL(string: "\(pan123RedirectURI)?code=test-code&state=test-state")!

    #expect(OAuthCallbackURLMatcher.matches(
        callback,
        registeredRedirectURI: pan123RedirectURI,
        callbackScheme: "primuse"
    ))
}

@Test func oauthCallbackTreatsSchemeAndHostAsCaseInsensitive() {
    let callback = URL(string: "PRIMUSE://OAUTH/123pan/callback?code=test-code&state=test-state")!

    #expect(OAuthCallbackURLMatcher.matches(
        callback,
        registeredRedirectURI: pan123RedirectURI,
        callbackScheme: "primuse"
    ))
}

@Test func oauthCallbackRejectsWrongSchemeHostOrPath() {
    let invalidURLs = [
        "other://oauth/123pan/callback?code=test-code&state=test-state",
        "primuse://other/123pan/callback?code=test-code&state=test-state",
        "primuse://oauth/123pan/other?code=test-code&state=test-state",
        "primuse://oauth/123Pan/callback?code=test-code&state=test-state",
        "primuse://oauth/123pan/callback/?code=test-code&state=test-state",
        "primuse://oauth:443/123pan/callback?code=test-code&state=test-state",
        "primuse://oauth/123pan/%63allback?code=test-code&state=test-state",
        "primuse:/123pan/callback?code=test-code&state=test-state",
    ]

    for urlString in invalidURLs {
        let callback = URL(string: urlString)!
        #expect(!OAuthCallbackURLMatcher.matches(
            callback,
            registeredRedirectURI: pan123RedirectURI,
            callbackScheme: "primuse"
        ))
    }
}

@Test func oauthCallbackRejectsUnexpectedAuthorityComponents() {
    let callback = URL(string: "primuse://user@oauth/123pan/callback?code=test-code&state=test-state")!

    #expect(!OAuthCallbackURLMatcher.matches(
        callback,
        registeredRedirectURI: pan123RedirectURI,
        callbackScheme: "primuse"
    ))
}

@Test func oauthCallbackKeepsHTTPSRelayCompatibility() {
    let relayedCallback = URL(string: "primuse://baidu/callback?code=test-code&state=test-state")!

    #expect(OAuthCallbackURLMatcher.matches(
        relayedCallback,
        registeredRedirectURI: "https://baidu.callback.welape.com/",
        callbackScheme: "primuse"
    ))
}

@Test func oauthCallbackRelayStillRejectsWrongScheme() {
    let callback = URL(string: "other://baidu/callback?code=test-code&state=test-state")!

    #expect(!OAuthCallbackURLMatcher.matches(
        callback,
        registeredRedirectURI: "https://baidu.callback.welape.com/",
        callbackScheme: "primuse"
    ))
}
