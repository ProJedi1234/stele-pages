import Foundation
import Testing

@testable import SteleCore

@Suite("Live page client injection")
struct LivePageTests {
    let slug = Slug(unchecked: "amber-willow-heron")
    let id = UUID(uuidString: "57B6EC52-C9E3-4C46-A72D-1F7711F81234")!

    @Test func insertsBeforeTheRealBodyClose() {
        let html = """
        <!doctype html><html><head><script>const sample = "</body>";</script></head>
        <body><!-- </body> --><style>.x::after { content: "</body>" }</style><p>Hello</p></body></html>
        """
        let result = LivePage.inject(html: html, slug: slug, id: id, revision: 42)

        #expect(result.contains(#"new EventSource(c.events)"#))
        #expect(result.contains(#""events":"/pages/amber-willow-heron/events?id=57b6ec52-c9e3-4c46-a72d-1f7711f81234""#))
        #expect(result.contains(#""revision":"42""#))
        #expect(result.hasSuffix("</body></html>"))
        #expect(result.firstRange(of: "data-stele-live")!.lowerBound > result.firstRange(of: "<p>Hello</p>")!.upperBound)
    }

    @Test func insertsBeforeHtmlWhenThereIsNoBodyAndAppendsToAFragment() {
        let document = "<html><main>Hello</main></html>"
        let fragment = "<main>Hello</main>"

        #expect(LivePage.inject(html: document, slug: slug, id: id, revision: 1).hasSuffix("</script></html>"))
        let injectedFragment = LivePage.inject(html: fragment, slug: slug, id: id, revision: 1)
        #expect(injectedFragment.hasPrefix(fragment))
        #expect(injectedFragment.hasSuffix("</script>"))
    }

    @Test func honorsCaseInsensitiveOptOutWithFlexibleAttributeSyntax() {
        let pages = [
            #"<meta name="stele-live" content="off"><body>x</body>"#,
            #"<META CONTENT=' OFF ' NAME='STELE-LIVE'><body>x</body>"#,
            #"<meta content=Off name=Stele-Live><body>x</body>"#,
            #"<meta name="stele-live" content="o&#102;f"><body>x</body>"#,
            #"<meta name="stele-live" content="&#x6f;ff"><body>x</body>"#,
        ]

        for html in pages {
            #expect(LivePage.inject(html: html, slug: slug, id: id, revision: 1) == html)
        }
    }

    @Test func ignoresClosingTagsInsideRcdataAndTemplates() {
        let html = """
        <html><head><title>Example </body></title></head><body>
        <textarea>literal </body> marker</textarea>
        <template><section>template </body> marker</section></template>
        <p>Real body</p></body></html>
        """
        let result = LivePage.inject(html: html, slug: slug, id: id, revision: 1)
        let script = result.firstRange(of: "<script data-stele-live>")!
        let paragraph = result.firstRange(of: "<p>Real body</p>")!

        #expect(script.lowerBound >= paragraph.upperBound)
        #expect(result.hasSuffix("</body></html>"))
    }

    @Test func doesNotAppendAnInertClientToUnterminatedRawText() {
        for html in ["<script>const x = 1", "<style>body {}", "<textarea>draft", "<plaintext>rest"] {
            #expect(LivePage.inject(html: html, slug: slug, id: id, revision: 1) == html)
        }
    }

    @Test func similarMarkupDoesNotOptOut() {
        let pages = [
            #"<!-- <meta name="stele-live" content="off"> --><body>x</body>"#,
            #"<script>const x = '<meta name="stele-live" content="off">'</script><body>x</body>"#,
            #"<meta name="stele-live-extra" content="off"><body>x</body>"#,
            #"<meta name="stele-live" content="on"><body>x</body>"#,
        ]

        for html in pages {
            #expect(LivePage.inject(html: html, slug: slug, id: id, revision: 1).contains("data-stele-live"))
        }
    }

    @Test(arguments: ["<!-- unfinished comment", "<div class=\"unfinished", "<div", "<"])
    func truncatedMarkupIsServedUnchanged(_ html: String) {
        #expect(LivePage.inject(html: html, slug: slug, id: id, revision: 1) == html)
    }

    @Test func leavesRestrictiveContentSecurityPolicyUntouched() {
        let policy = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'">"#
        let html = "<html><head>\(policy)</head><body>x</body></html>"
        let result = LivePage.inject(html: html, slug: slug, id: id, revision: .max)

        #expect(result.contains(policy))
        #expect(result.contains("default-src 'none'") )
        #expect(result.contains(#""revision":"9223372036854775807""#))
    }

}
