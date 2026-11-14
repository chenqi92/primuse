import Foundation
import Testing
@testable import PrimuseKit

@Suite("115 open platform protocol")
struct Pan115APIProtocolTests {

    // MARK: - 业务包络

    @Test("state 为真即成功,空的 error / errno 不算失败")
    func successEnvelopeIgnoresEmptyErrorFields() {
        let body = #"{"state":true,"code":0,"message":"","error":"","errno":0,"data":[]}"#
        #expect(Pan115APIProtocol.envelope(of: Data(body.utf8)) == .success)
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":1,"data":{}}"#.utf8)) == .success)
        // 没有 state 的老写法:code 缺省或为 0 是成功,非 0 是失败。
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"code":0,"data":[]}"#.utf8)) == .success)
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"code":20018,"message":"参数错误"}"#.utf8))
                == .failure(code: 20018, message: "参数错误"))
        #expect(Pan115APIProtocol.envelope(of: Data("<html></html>".utf8)) == nil)
    }

    @Test("access_token 失效的业务码触发刷新")
    func authorizationCodesAskForRefresh() {
        for code in [99, 401, 40_140_123, 40_140_124, 40_140_125, 40_140_126] {
            let body = #"{"state":false,"code":\#(code),"message":"access_token 无效","data":[]}"#
            #expect(Pan115APIProtocol.envelope(of: Data(body.utf8)) == .tokenExpired, "code \(code)")
        }
        // 4010xxxx(参数缺失)不是 token 的问题。
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"code":40100000,"message":"参数缺失"}"#.utf8))
                == .failure(code: 40_100_000, message: "参数缺失"))
    }

    @Test("限流按业务码或说法识别,优先于授权类业务码")
    func rateLimitIsRecognizedFromCodeOrMessage() {
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"code":40140117,"message":"刷新太频繁"}"#.utf8))
                == .rateLimited)
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"code":0,"message":"请求过于频繁，请稍后再试"}"#.utf8))
                == .rateLimited)
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"error":"Too Many Requests"}"#.utf8))
                == .rateLimited)
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"code":50001,"message":"今日已达上限"}"#.utf8))
                == .rateLimited)
    }

    @Test("出错时空的 data 不会被当成空文件夹")
    func failedListingIsNotAnEmptyFolder() {
        let body = #"{"state":false,"code":20130827,"message":"系统繁忙","data":[]}"#
        #expect(Pan115APIProtocol.envelope(of: Data(body.utf8)) == .failure(code: 20_130_827, message: "系统繁忙"))
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"message":"文件不存在或已删除"}"#.utf8))
                == .notFound)
    }

    // MARK: - 刷新

    @Test("成功体带空 error 时照样收下轮换后的 refresh_token")
    func refreshSuccessWithEmptyErrorKeepsRotation() {
        let body = #"{"state":1,"code":0,"message":"","error":"","errno":0,"data":{"access_token":"AT","refresh_token":"RT2","expires_in":7200}}"#
        guard case .refreshed(let grant) = Pan115APIProtocol.refreshOutcome(Data(body.utf8)) else {
            Issue.record("Success body was rejected")
            return
        }
        #expect(grant.accessToken == "AT")
        #expect(grant.refreshToken == "RT2")
        #expect(grant.expiresIn == 7200)
        let stringExpiry = #"{"state":true,"data":{"access_token":"AT","refresh_token":"RT3","expires_in":"7200"}}"#
        #expect(Pan115APIProtocol.refreshOutcome(Data(stringExpiry.utf8))
                == .refreshed(.init(accessToken: "AT", refreshToken: "RT3", expiresIn: 7200, tokenType: nil)))
    }

    @Test("已被用过 / 失效的 refresh_token 要用户重新拿一个")
    func consumedRefreshTokenIsInvalid() {
        for code in [40_140_114, 40_140_115, 40_140_116, 40_140_119, 40_140_120] {
            let body = #"{"state":false,"code":\#(code),"message":"refresh_token 无效","error":"refresh_token 无效","errno":\#(code),"data":[]}"#
            #expect(Pan115APIProtocol.refreshOutcome(Data(body.utf8))
                    == .invalidRefreshToken(code: code, message: "refresh_token 无效"), "code \(code)")
        }
        // 「超出授权应用个数上限」带着「上限」二字,也不能当成限流。
        #expect(Pan115APIProtocol.refreshOutcome(Data(#"{"state":false,"code":40140122,"message":"超出授权应用个数上限"}"#.utf8))
                == .invalidRefreshToken(code: 40_140_122, message: "超出授权应用个数上限"))
        // state 为假时,body 里夹带的 token 不算数。
        let rejected = #"{"state":false,"code":40140116,"data":{"access_token":"rejected"}}"#
        #expect(Pan115APIProtocol.refreshOutcome(Data(rejected.utf8))
                == .invalidRefreshToken(code: 40_140_116, message: ""))
    }

    @Test("刷新太频繁是可以重试的限流,不是授权失效")
    func refreshRateLimitIsRetryable() {
        let body = #"{"state":false,"code":40140117,"message":"access_token 刷新太频繁","data":[]}"#
        #expect(Pan115APIProtocol.refreshOutcome(Data(body.utf8)) == .rateLimited)
        #expect(Pan115APIProtocol.refreshOutcome(Data(#"{"state":false,"code":40110000,"message":"请求异常需要重试"}"#.utf8))
                == .temporaryFailure(code: 40_110_000, message: "请求异常需要重试"))
    }

    @Test("说成功却没给 token、或只有非空 error 时仍是失败")
    func bodiesWithoutTokensStillFail() {
        #expect(Pan115APIProtocol.refreshOutcome(Data(#"{"state":true,"data":{"access_token":" "}}"#.utf8))
                == .temporaryFailure(code: nil, message: ""))
        #expect(Pan115APIProtocol.refreshOutcome(Data(#"{"error":"something went wrong"}"#.utf8))
                == .temporaryFailure(code: nil, message: "something went wrong"))
        #expect(Pan115APIProtocol.refreshOutcome(Data("not json".utf8)) == .temporaryFailure(code: nil, message: ""))
    }

    // MARK: - 直链与列表字段

    @Test("downurl:有地址、没这个文件、有文件没地址三种")
    func downloadLinkShapes() throws {
        let link = try #require(JSONSerialization.jsonObject(with: Data(
            #"{"state":true,"data":{"77":{"file_name":"a.flac","url":{"url":"https://cdn.115.example/a.flac"}}}}"#.utf8)) as? [String: Any])
        #expect(Pan115APIProtocol.downloadLink(in: link)
                == .link(fileID: "77", url: URL(string: "https://cdn.115.example/a.flac")!))
        let missing = try #require(JSONSerialization.jsonObject(with: Data(#"{"state":true,"data":[]}"#.utf8)) as? [String: Any])
        #expect(Pan115APIProtocol.downloadLink(in: missing) == .missingFile)
        let unavailable = try #require(JSONSerialization.jsonObject(with: Data(
            #"{"state":true,"data":{"78":{"url":{"url":""}}}}"#.utf8)) as? [String: Any])
        #expect(Pan115APIProtocol.downloadLink(in: unavailable) == .unavailable(fileID: "78"))
    }

    @Test("列表时间戳认秒和毫秒,空值和 0 不给日期")
    func listingTimestamps() {
        #expect(Pan115APIProtocol.date(fromTimestamp: "1700000000") == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(Pan115APIProtocol.date(fromTimestamp: NSNumber(value: 1_700_000_000_000)) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(Pan115APIProtocol.date(fromTimestamp: "0") == nil)
        #expect(Pan115APIProtocol.date(fromTimestamp: nil) == nil)
        #expect(Pan115APIProtocol.intValue("1200") == 1200)
    }

    @Test("只给 115 的接口主机限频")
    func apiHosts() {
        #expect(Pan115APIProtocol.isAPIHost("proapi.115.com"))
        #expect(Pan115APIProtocol.isAPIHost("PassportAPI.115.com"))
        #expect(!Pan115APIProtocol.isAPIHost("cdnfhnfdfs.115cdn.net"))
        #expect(!Pan115APIProtocol.isAPIHost(nil))
    }

    @Test("115 播放只多预读一块")
    func playbackPrefetchIsCapped() {
        #expect(RangeStreamingPrefetchPolicy.aheadCount(for: .pan115, defaultValue: 4) == 1)
        #expect(RangeStreamingPrefetchPolicy.aheadCount(for: .pan115, defaultValue: 0) == 0)
    }
}
