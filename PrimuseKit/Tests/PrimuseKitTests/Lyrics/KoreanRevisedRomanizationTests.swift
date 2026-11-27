import Testing
@testable import PrimuseKit

struct KoreanRevisedRomanizationTests {
    @Test(arguments: [
        ("같이", "gachi"),
        ("국물", "gungmul"),
        ("신라", "silla"),
        ("좋다", "jota"),
        ("한국어", "hangugeo"),
    ])
    func requiredSoundChanges(_ input: String, _ expected: String) {
        #expect(KoreanRevisedRomanization.romanize(input) == expected)
    }

    @Test(arguments: [
        // 连音（含双收尾只移后一个、ㄲ/ㅆ 整个移过去）
        ("있어", "isseo"),
        ("없어", "eopseo"),
        ("읽어", "ilgeo"),
        ("앉아", "anja"),
        ("맛있다", "masitda"),
        ("꽃이", "kkochi"),
        ("같은", "gateun"),
        // ㅎ 脱落与激音化
        ("좋아", "joa"),
        ("많이", "mani"),
        ("괜찮아", "gwaenchana"),
        ("않다", "anta"),
        ("축하", "chuka"),
        ("밝히다", "balkida"),
        ("놓는", "nonneun"),
        // 腭化
        ("굳이", "guji"),
        ("해돋이", "haedoji"),
        ("닫히다", "dachida"),
        // 鼻音化
        ("먹는", "meongneun"),
        ("십년", "simnyeon"),
        ("빛나는", "binnaneun"),
        ("끝나", "kkeunna"),
        ("없는", "eomneun"),
        ("심리", "simni"),
        ("종로", "jongno"),
        ("국력", "gungnyeok"),
        // 流音化
        ("설날", "seollal"),
        ("몰라", "molla"),
        ("뚫는", "ttulleun"),
        // 紧音化不写出来、ㅇ 后的 ㅎ 保留
        ("학교", "hakgyo"),
        ("사랑해", "saranghae"),
        ("전화", "jeonhwa"),
        // 词尾代表音
        ("빛", "bit"),
        ("닭", "dak"),
        ("삶", "sam"),
        ("여덟", "yeodeol"),
        ("의", "ui"),
    ])
    func pronunciationRules(_ input: String, _ expected: String) {
        #expect(KoreanRevisedRomanization.romanize(input) == expected)
    }

    @Test func keepsSpacingPunctuationAndLatin() {
        #expect(KoreanRevisedRomanization.romanize("안녕하세요, 여러분!") == "annyeonghaseyo, yeoreobun!")
        #expect(KoreanRevisedRomanization.romanize("Baby 사랑해 2번") == "Baby saranghae 2beon")
        // 音变只在一个词里发生，空格两边互不影响。
        #expect(KoreanRevisedRomanization.romanize("국 물") == "guk mul")
    }

    @Test func standaloneJamoBecomeLetters() {
        #expect(KoreanRevisedRomanization.romanize("ㅋㅋ") == "kk")
        #expect(KoreanRevisedRomanization.romanize("ㅠㅠ") == "yuyu")
    }
}
