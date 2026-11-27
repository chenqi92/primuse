import Testing
@testable import PrimuseKit

struct LyricTransliterationTests {
    // MARK: 印地文

    @Test(arguments: [
        ("हिन्दी", "hindī"),
        ("दिल", "dil"),
        ("प्यार", "pyār"),
        ("नमस्ते", "namaste"),
        ("कमल", "kamal"),
        ("ध\u{0921}\u{093C}कन", "dharkan"),
        ("ध\u{095C}कन", "dharkan"),
        ("मित्र", "mitra"),
        ("समझ", "samajh"),
        ("हमेशा", "hameshā"),
        ("\u{091C}\u{093C}िंदगी", "zindagī"),
        ("\u{095B}िंदगी", "zindagī"),
        ("न", "na"),
    ])
    func hindiRequiredWords(_ input: String, _ expected: String) {
        #expect(HindiLyricTransliteration.romanize(input) == expected)
    }

    @Test(arguments: [
        // 词中 V C _ C V 从右往左省
        ("अपना", "apnā"),
        ("सपना", "sapnā"),
        ("समझना", "samajhnā"),
        ("बचपन", "bachpan"),
        ("कहना", "kahnā"),
        ("भारत", "bhārat"),
        // 省了会连出三个辅音就不省、复辅音
        ("डॉक्टर", "doktar"),
        ("प्रकाश", "prakāsh"),
        ("प्रेम", "prem"),
        ("सूर्य", "sūrya"),
        ("दोस्त", "dost"),
        ("ज्ञान", "gyān"),
        // anusvara、chandrabindu、visarga、nukta
        ("संबंध", "sambandh"),
        ("संगीत", "sangīt"),
        ("मैं", "main"),
        ("हाँ", "hān"),
        ("दुःख", "duhkh"),
        ("इश्क\u{093C}", "ishq"),
        ("फ\u{093C}िल्म", "film"),
        ("ऋषि", "rishi"),
        ("और", "aur"),
    ])
    func hindiSchwaDeletionAndMarks(_ input: String, _ expected: String) {
        #expect(HindiLyricTransliteration.romanize(input) == expected)
    }

    @Test func hindiKeepsSpacingPunctuationAndLatin() {
        #expect(HindiLyricTransliteration.romanize("तुम मेरे हो।") == "tum mere ho.")
        #expect(HindiLyricTransliteration.romanize("Baby, तेरा दिल २०२४") == "Baby, terā dil 2024")
    }

    // MARK: 俄文

    @Test(arguments: [
        ("Русский", "Russkiy"),
        ("Привет", "Privet"),
        ("Хорошо", "Khorosho"),
        ("Щука", "Shchuka"),
        ("всё", "vsyo"),
        ("ЩУКА", "SHCHUKA"),
        ("Ёлка", "Yolka"),
        ("объект", "obekt"),
        ("Я люблю тебя", "Ya lyublyu tebya"),
        ("Hello, мир!", "Hello, mir!"),
        ("Это жизнь", "Eto zhizn"),
    ])
    func russian(_ input: String, _ expected: String) {
        #expect(CyrillicLyricTransliteration.romanizeRussian(input) == expected)
    }

    // MARK: 乌克兰文（2010 年官方转写的示例）

    @Test(arguments: [
        ("Згорани", "Zghorany"),
        ("Розгон", "Rozghon"),
        ("Їжакевич", "Yizhakevych"),
        ("Кадиївка", "Kadyivka"),
        ("Київ", "Kyiv"),
        ("Україна", "Ukraina"),
        ("Юрій", "Yurii"),
        ("Олексій", "Oleksii"),
        ("Гадяч", "Hadiach"),
        ("Яготин", "Yahotyn"),
        ("Єнакієве", "Yenakiieve"),
        ("Знам'янка", "Znamianka"),
        ("Щербухи", "Shcherbukhy"),
        ("Ґалаґан", "Galagan"),
        ("Любов моя", "Liubov moia"),
    ])
    func ukrainian(_ input: String, _ expected: String) {
        #expect(CyrillicLyricTransliteration.romanizeUkrainian(input) == expected)
    }

    @Test func ukrainianIsDetectedForTheWholeSong() {
        #expect(CyrillicLyricTransliteration.isUkrainian(["Ти моя любов", "Привіт"]))
        #expect(!CyrillicLyricTransliteration.isUkrainian(["Ты моя любовь", "Привет"]))

        let ukrainianSong = [
            LyricLine(id: "a", timestamp: 1, text: "Ти моя любов"),
            LyricLine(id: "b", timestamp: 2, text: "Привіт, друже"),
        ]
        let plan = LyricRomanizationPlanner.plan(lines: ukrainianSong, generates: true, enabledLanguages: [.other])
        #expect(plan.groups.map(\.languageCode) == ["uk"])
        #expect(plan.groups.first?.candidates.map(\.lineID) == ["a", "b"])

        let russianSong = [LyricLine(id: "a", timestamp: 1, text: "Ты моя любовь")]
        #expect(LyricRomanizationPlanner.plan(lines: russianSong, generates: true, enabledLanguages: [.other])
            .groups.map(\.languageCode) == ["ru"])

        let hindiSong = [LyricLine(id: "a", timestamp: 1, text: "तुम ही हो")]
        #expect(LyricRomanizationPlanner.plan(lines: hindiSong, generates: true, enabledLanguages: [.other])
            .groups.map(\.languageCode) == ["hi"])
    }
}
