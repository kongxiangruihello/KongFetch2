import XCTest
@testable import KongFetchCore

final class TextCleanupTests: XCTestCase {
    func testJoinsChineseLinesAndKeepsIndentedParagraphs() {
        let input = "　　子曰：学而时习之，不亦说乎？有朋自远方来，不亦乐\n乎？人不知而不愠，不亦君子乎？\n" +
            "　　有子曰：其为人也孝弟，而好犯上者，鲜矣；不好犯\n上而好作乱者，未之有也。"
        XCTAssertEqual(TextCleanup.joinLines(input),
                       "　　子曰：学而时习之，不亦说乎？有朋自远方来，不亦乐乎？人不知而不愠，不亦君子乎？\n" +
                       "　　有子曰：其为人也孝弟，而好犯上者，鲜矣；不好犯上而好作乱者，未之有也。")
    }

    func testJoinsEnglishLinesAndHyphenatedWords() {
        let input = "The Analects is a compre-\nhensive collection of sayings\nattributed to Confucius and his\ndisciples."
        XCTAssertEqual(TextCleanup.joinLines(input),
                       "The Analects is a comprehensive collection of sayings attributed to Confucius and his disciples.")
    }

    func testBlankLineAfterEveryLineIsIgnored() {
        XCTAssertEqual(TextCleanup.joinLines("学而时习之，\n\n不亦说乎？\n\n有朋自远方来"), "学而时习之，不亦说乎？有朋自远方来")
    }

    func testListItemsAndHeadingsStayOnTheirOwnLines() {
        XCTAssertEqual(TextCleanup.joinLines("要点如下：\n1. 学而\n2. 为政"), "要点如下：\n1. 学而\n2. 为政")
        let heading = "第一章 学而\n子曰：学而时习之，不亦说乎？有朋自远方来，不亦乐乎？"
        XCTAssertEqual(TextCleanup.joinLines(heading), heading)
    }

    func testShortLineEndingASentenceEndsTheParagraph() {
        let input = "子曰：学而时习之，不亦说乎？有朋自远方来，不亦乐乎？人\n不知而不愠，不亦君子乎？\n有子曰：其为人也孝弟，而好犯上者，鲜矣；不好犯上\n而好作乱者，未之有也。"
        XCTAssertEqual(TextCleanup.joinLines(input),
                       "子曰：学而时习之，不亦说乎？有朋自远方来，不亦乐乎？人不知而不愠，不亦君子乎？\n" +
                       "有子曰：其为人也孝弟，而好犯上者，鲜矣；不好犯上而好作乱者，未之有也。")
    }

    func testChinesePunctuationLeavesNumbersAndURLsAlone() {
        let input = "孔子曰:学而时习之,不亦说乎?见(论语)第1.2节, 版本 3.14, see http://a.b/c?x=1."
        XCTAssertEqual(TextCleanup.chinesePunctuation(input),
                       "孔子曰：学而时习之，不亦说乎？见（论语）第1.2节，版本 3.14, see http://a.b/c?x=1.")
    }

    func testQuotesAndEllipsis() {
        XCTAssertEqual(TextCleanup.chinesePunctuation("他说 \"学而时习之\" ... 然后"), "他说“学而时习之”……然后")
        XCTAssertEqual(TextCleanup.chinesePunctuation("子曰。"), "子曰。")
        XCTAssertEqual(TextCleanup.chinesePunctuation("学而时习之."), "学而时习之。")
    }

    func testEnglishAndParenthesesAroundLatinAreUntouched() {
        XCTAssertEqual(TextCleanup.chinesePunctuation("Hello, world. (Note: \"quoted\")"), "Hello, world. (Note: \"quoted\")")
        XCTAssertEqual(TextCleanup.chinesePunctuation("参见 Smith (2001) 认为"), "参见 Smith (2001) 认为")
    }

    func testNormalizeSpaces() {
        let input = "中 国 思 想 史\u{00A0}研究  ，  第 1 章\u{200B}\n\n\n\nEnglish   words  here  \n"
        XCTAssertEqual(TextCleanup.normalizeSpaces(input), "中国思想史研究，第 1 章\n\nEnglish words here")
        XCTAssertEqual(TextCleanup.normalizeSpaces("He said “hello” to me"), "He said “hello” to me")
        XCTAssertEqual(TextCleanup.normalizeSpaces("　　子曰 学而"), "　　子曰学而")
    }

    func testDefaultCleanupOfPDFText() {
        XCTAssertEqual(TextCleanup.apply(TextCleanup.defaultOperations, to: "子曰:学而时习之,不亦说\r\n乎?"),
                       "子曰：学而时习之，不亦说乎？")
    }

    func testTraditionalAndSimplified() {
        XCTAssertEqual(TextCleanup.convertScript("學而時習之，不亦說乎", toSimplified: true), "学而时习之，不亦说乎")
        XCTAssertEqual(TextCleanup.convertScript("学而时习之", toSimplified: false), "學而時習之")
        XCTAssertEqual(TextCleanup.apply([.toSimplified, .toTraditional], to: "學習"), "学习")
    }
}
