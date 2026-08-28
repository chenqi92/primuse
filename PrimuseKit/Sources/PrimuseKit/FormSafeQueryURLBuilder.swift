import Foundation

/// Builds query URLs whose values survive both RFC query parsing and
/// `application/x-www-form-urlencoded` style decoding.
public enum FormSafeQueryURLBuilder {
    public static func percentEncodedQuery(from components: URLComponents) -> String? {
        components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }

    public static func url(from components: URLComponents) -> URL? {
        var encoded = components
        if let query = percentEncodedQuery(from: components) {
            encoded.percentEncodedQuery = query
        }
        return encoded.url
    }
}
