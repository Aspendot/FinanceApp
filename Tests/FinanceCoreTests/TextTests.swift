import Testing
@testable import FinanceCore

@Suite("TextFold")
struct TextFoldTests {
    @Test("Half-width katakana folds like full-width")
    func halfWidthKana() {
        #expect(TextFold.key("ﾌｧﾐﾘｰﾏｰﾄ") == TextFold.key("ファミリーマート"))
    }

    @Test("Dash look-alikes fold together")
    func dashes() {
        #expect(TextFold.key("フアミリ―マ―ト") == TextFold.key("ファミリーマート"))
        #expect(TextFold.key("セブン－イレブン") == TextFold.key("セブン-イレブン"))
        #expect(TextFold.key("A−B") == TextFold.key("A-B"))
    }

    @Test("Full-width Latin, case and spaces")
    func latin() {
        #expect(TextFold.key("ＴＥＳＴ　ＳＨＯＰ 駅前店") == "testshop駅前店")
    }

    @Test("Latin keys use Unicode case folding")
    func unicodeCase() {
        #expect(TextFold.key("Lumi\u{00DF}o") == TextFold.key("LUMISSO"))
    }

    @Test("A spaced voiced mark recomposes")
    func voicedMark() {
        #expect(TextFold.key("ウ゛ァン") == TextFold.key("ヴァン"))
    }

    @Test("Wave dash variants fold together")
    func waves() {
        #expect(TextFold.key("10〜20") == TextFold.key("10～20"))
    }
}

@Suite("Yen")
struct YenTests {
    @Test("Parses the written forms", arguments: zip(
        ["1,234円", "１，２３４円", "¥1,234", "￥12,345", "980.00", "-1,500", "▲300円", "0円", "1234567", "1,234 円"],
        [1234, 1234, 1234, 12345, 980, -1500, -300, 0, 1_234_567, 1234]
    ))
    func parses(_ input: String, _ expected: Int) {
        #expect(Yen.parse(input) == expected)
    }

    @Test("Accepts the full signed Int range with or without grouping")
    func signedBounds() {
        #expect(Yen.parse(String(Int.max)) == Int.max)
        #expect(Yen.parse(String(Int.min)) == Int.min)
        #expect(Yen.parse("-9,223,372,036,854,775,808") == Int.min)
        #expect(Yen.parse("9,223,372,036,854,775,808") == nil)
    }

    @Test("Trims line breaks and space after a sign")
    func surroundingWhitespace() {
        #expect(Yen.parse("\r\n- 100\n") == -100)
    }

    @Test("Rejects what is not a whole-yen amount",
          arguments: ["", "円", "12.50", "1,23", "12,3456", "abc", "1.234,00", "--5", ",123", "10\u{00B2}", "\u{2469}"])
    func rejects(_ input: String) {
        #expect(Yen.parse(input) == nil)
    }
}
