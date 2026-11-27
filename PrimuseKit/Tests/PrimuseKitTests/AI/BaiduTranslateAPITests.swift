import Foundation
import Testing
@testable import PrimuseKit

struct BaiduTranslateAPITests {
    @Test func languageCodesFollowBaiduTable() {
        #expect(BaiduTranslateAPI.languageCode(for: "zh-Hans") == "zh")
        #expect(BaiduTranslateAPI.languageCode(for: "zh-Hant") == "cht")
        #expect(BaiduTranslateAPI.languageCode(for: "zh_TW") == "cht")
        #expect(BaiduTranslateAPI.languageCode(for: "zh-HK") == "cht")
        #expect(BaiduTranslateAPI.languageCode(for: "zh-CN") == "zh")
        #expect(BaiduTranslateAPI.languageCode(for: "zh") == "zh")
        #expect(BaiduTranslateAPI.languageCode(for: "ja") == "jp")
        #expect(BaiduTranslateAPI.languageCode(for: "ko-KR") == "kor")
        #expect(BaiduTranslateAPI.languageCode(for: "fr") == "fra")
        #expect(BaiduTranslateAPI.languageCode(for: "es-MX") == "spa")
        #expect(BaiduTranslateAPI.languageCode(for: "pt-BR") == "pt")
        #expect(BaiduTranslateAPI.languageCode(for: "ar") == "ara")
        #expect(BaiduTranslateAPI.languageCode(for: "fa") == "per")
        #expect(BaiduTranslateAPI.languageCode(for: "uk") == "ukr")
        #expect(BaiduTranslateAPI.languageCode(for: "vi") == "vie")
        #expect(BaiduTranslateAPI.languageCode(for: "en") == "en")
        #expect(BaiduTranslateAPI.languageCode(for: "xx") == nil)
        #expect(BaiduTranslateAPI.languageCode(for: "") == nil)
    }

    @Test func unknownSourceFallsBackToAutomaticDetection() {
        #expect(BaiduTranslateAPI.sourceCode(for: nil) == "auto")
        #expect(BaiduTranslateAPI.sourceCode(for: "tlh") == "auto")
        #expect(BaiduTranslateAPI.sourceCode(for: "ja") == "jp")
        #expect(BaiduTranslateAPI.supportsTarget("zh-Hans"))
        #expect(!BaiduTranslateAPI.supportsTarget("tlh"))
    }

    /// 百度文档里的示例：appid=2015063000000001、q=apple、salt=1435660288、密钥 12345678。
    @Test func signatureMatchesDocumentedExample() {
        let input = BaiduTranslateAPI.signingInput(
            appID: "2015063000000001",
            query: "apple",
            salt: "1435660288",
            secretKey: "12345678"
        )
        #expect(input == "2015063000000001apple143566028812345678")
        #if canImport(CryptoKit)
        #expect(BaiduTranslateAPI.sign(
            appID: "2015063000000001",
            query: "apple",
            salt: "1435660288",
            secretKey: "12345678"
        ) == "f89f9594663708c1605f3d736d01d2d4")
        #endif
    }

    @Test func formBodyEncodesReservedCharacters() {
        let body = BaiduTranslateAPI.formBody(
            query: "a b+c&d=e\n你好",
            from: "auto",
            to: "zh",
            appID: "123",
            salt: "9",
            sign: "abc"
        )
        let text = String(decoding: body, as: UTF8.self)
        #expect(text == "q=a%20b%2Bc%26d%3De%0A%E4%BD%A0%E5%A5%BD&from=auto&to=zh&appid=123&salt=9&sign=abc")
    }

    @Test func queryLinesNeverSplitALyricLine() {
        #expect(BaiduTranslateAPI.queryLine("  one\ntwo \r\n three  ") == "one two three")
        #expect(BaiduTranslateAPI.queryLine("   ") == "")
        #expect(BaiduTranslateAPI.query(for: ["a\nb", "c"]) == "a b\nc")
    }

    @Test func batchesRespectByteLimitAndSkipBlankLines() {
        let texts = ["aaaa", "", "bbbb", "cccc", "  ", "dddd"]
        // 每行 4 字节，加换行：两行 9 字节，三行 14 字节。
        let batches = BaiduTranslateAPI.batches(texts, maximumBytes: 9)
        #expect(batches == [[0, 2], [3, 5]])
        #expect(BaiduTranslateAPI.batches(texts, maximumBytes: 100) == [[0, 2, 3, 5]])
        // 单独一行就超长的自己成一批。
        #expect(BaiduTranslateAPI.batches(["x", String(repeating: "长", count: 10), "y"], maximumBytes: 6) == [[0], [1], [2]])
        #expect(BaiduTranslateAPI.batches([]) == [])
    }

    @Test func decodesResultsInOrder() throws {
        let data = Data(#"{"from":"en","to":"zh","trans_result":[{"src":"Hello","dst":"你好"},{"src":"World","dst":"世界"}]}"#.utf8)
        let result = try BaiduTranslateAPI.decodeResponse(data, lines: ["Hello", "World"])
        #expect(result == ["你好", "世界"])
    }

    @Test func realignsBySourceWhenCountsDiffer() throws {
        let data = Data(#"{"from":"en","to":"zh","trans_result":[{"src":"Again","dst":"又一次"},{"src":"Hello","dst":"你好"},{"src":"Again","dst":"再一次"}]}"#.utf8)
        let result = try BaiduTranslateAPI.decodeResponse(data, lines: ["Hello", "Again", "Missing", "Again", " "])
        #expect(result == ["你好", "又一次", nil, "再一次", nil])
    }

    @Test func emptyTranslationsBecomeNil() throws {
        let data = Data(#"{"trans_result":[{"src":"a","dst":"  "},{"src":"b","dst":"乙"}]}"#.utf8)
        #expect(try BaiduTranslateAPI.decodeResponse(data, lines: ["a", "b"]) == [nil, "乙"])
    }

    @Test func serviceErrorsAreClassified() {
        func error(_ json: String) -> BaiduTranslateAPI.ServiceError? {
            do {
                _ = try BaiduTranslateAPI.decodeResponse(Data(json.utf8), lines: ["x"])
                return nil
            } catch let error as BaiduTranslateAPI.ServiceError {
                return error
            } catch {
                return nil
            }
        }
        let signature = error(#"{"error_code":"54001","error_msg":"Invalid Sign"}"#)
        #expect(signature?.kind == .signature)
        #expect(signature?.message == "Invalid Sign")
        #expect(signature?.isRetryable == false)
        // 有的应答把错误码写成数字。
        #expect(error(#"{"error_code":54003,"error_msg":"Invalid Access Limit"}"#)?.kind == .rateLimited)
        #expect(error(#"{"error_code":54003}"#)?.isRetryable == true)
        #expect(error(#"{"error_code":"52003","error_msg":"UNAUTHORIZED USER"}"#)?.kind == .unauthorized)
        #expect(error(#"{"error_code":"54004"}"#)?.kind == .insufficientBalance)
        #expect(error(#"{"error_code":"58001"}"#)?.kind == .unsupportedLanguage)
        #expect(error(#"{"error_code":"90107"}"#)?.kind == .notVerified)
        #expect(error(#"{"error_code":"52001"}"#)?.isRetryable == true)
        #expect(error(#"{"error_code":"99999"}"#)?.kind == .other)
    }

    @Test func successCodeWithResultsIsNotAnError() throws {
        let data = Data(#"{"error_code":"52000","trans_result":[{"src":"a","dst":"甲"}]}"#.utf8)
        #expect(try BaiduTranslateAPI.decodeResponse(data, lines: ["a"]) == ["甲"])
    }

    @Test func malformedResponsesThrow() {
        #expect(throws: BaiduTranslateAPI.DecodeError.invalidResponse) {
            try BaiduTranslateAPI.decodeResponse(Data("not json".utf8), lines: ["a"])
        }
        #expect(throws: BaiduTranslateAPI.DecodeError.invalidResponse) {
            try BaiduTranslateAPI.decodeResponse(Data(#"{"from":"en"}"#.utf8), lines: ["a"])
        }
    }

    @Test func credentialsAreTrimmedAndMasked() {
        let credentials = BaiduTranslateAPI.Credentials(appID: " 20240101001234567 \n", secretKey: " key ")
        #expect(credentials.appID == "20240101001234567")
        #expect(credentials.secretKey == "key")
        #expect(credentials.isComplete)
        #expect(credentials.maskedAppID == "2024…4567")
        #expect(!BaiduTranslateAPI.Credentials(appID: "1", secretKey: " ").isComplete)
        #expect(BaiduTranslateAPI.Credentials(appID: "12345678", secretKey: "k").maskedAppID == "12345678")
    }
}
