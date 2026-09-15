import Foundation
import Testing
@testable import PrimuseKit

@Suite("SVG image detection")
struct SVGImageSupportTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test("A bare svg root is recognised")
    func bareRoot() {
        #expect(SVGImageSupport.looksLikeSVG(data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")))
        #expect(SVGImageSupport.looksLikeSVG(data("<SVG></SVG>")))
        #expect(SVGImageSupport.looksLikeSVG(data("  \n <svg/>")))
    }

    @Test("Declarations, comments and a doctype in front are skipped")
    func prologue() {
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- exported by some tool -->
        <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "svg11.dtd">
        <svg width="64" height="64"></svg>
        """
        #expect(SVGImageSupport.looksLikeSVG(data(text)))
    }

    @Test("A UTF-8 BOM does not hide the root element")
    func bom() {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(data("<svg></svg>"))
        #expect(SVGImageSupport.looksLikeSVG(bytes))
    }

    @Test("An HTML page that merely contains an inline svg is not an SVG")
    func htmlWithInlineSVG() {
        let page = "<html><body><h1>404</h1><svg><path d=\"M0 0\"/></svg></body></html>"
        #expect(!SVGImageSupport.looksLikeSVG(data(page)))
    }

    @Test("Bitmaps and junk are not SVG")
    func notSVG() {
        #expect(!SVGImageSupport.looksLikeSVG(Data([0x89, 0x50, 0x4E, 0x47])))
        #expect(!SVGImageSupport.looksLikeSVG(Data([0xFF, 0xD8, 0xFF])))
        #expect(!SVGImageSupport.looksLikeSVG(Data()))
        #expect(!SVGImageSupport.looksLikeSVG(data("<svgfoo></svgfoo>")))
        #expect(!SVGImageSupport.looksLikeSVG(data("not markup at all")))
    }

    @Test("An unterminated prologue does not loop forever")
    func unterminatedPrologue() {
        #expect(!SVGImageSupport.looksLikeSVG(data("<?xml version=\"1.0\"")))
        #expect(!SVGImageSupport.looksLikeSVG(data("<!-- never closed")))
        #expect(!SVGImageSupport.looksLikeSVG(data("<")))
    }

    @Test("Something larger than the cap is refused outright")
    func oversize() {
        var bytes = data("<svg>")
        bytes.append(Data(repeating: 0x20, count: SVGImageSupport.maximumBytes))
        #expect(!SVGImageSupport.looksLikeSVG(bytes))
    }

    @Test("Completeness needs a closing tag")
    func completeness() {
        #expect(SVGImageSupport.isCompleteSVG(data("<svg></svg>")))
        #expect(SVGImageSupport.isCompleteSVG(data("<svg></svg>\n  ")))
        #expect(SVGImageSupport.isCompleteSVG(data("<svg></SVG>")))
        // 下载被截断
        #expect(!SVGImageSupport.isCompleteSVG(data("<svg><path d=\"M0 0")))
        #expect(!SVGImageSupport.isCompleteSVG(Data([0x89, 0x50, 0x4E, 0x47])))
    }

    @Test("A reference is judged by its extension or query")
    func reference() {
        #expect(SVGImageSupport.referenceLooksLikeSVG("https://e.test/logo.svg"))
        #expect(SVGImageSupport.referenceLooksLikeSVG("https://e.test/logo.SVG"))
        #expect(SVGImageSupport.referenceLooksLikeSVG("https://e.test/logo?format=svg"))
        #expect(!SVGImageSupport.referenceLooksLikeSVG("https://e.test/logo.png"))
        #expect(!SVGImageSupport.referenceLooksLikeSVG(nil))
    }
}
