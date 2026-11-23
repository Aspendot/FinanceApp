import Testing
@testable import FinanceCore

@Suite("HTMLText")
struct HTMLTextTests {
    @Test("Drops head, style, script content and comments")
    func dropsNonVisibleContent() {
        let html = """
        <!DOCTYPE html>
        <html>
          <head>
            <title>Hidden Title</title>
            <style>body { color: #111; } /* hidden */</style>
          </head>
          <body>
            <!-- hidden comment -->
            <script type="text/javascript">
              if (1 < 2) { console.log("<b>hidden</b>"); }
            </script>
            <h1>Receipt</h1>
            <p>SAMPLE STORE</p>
          </body>
        </html>
        """

        #expect(HTMLText.plainText(html) == "Receipt\nSAMPLE STORE")
    }

    @Test("Formats HTML tables with pipe separators for cells and line breaks for rows")
    func formatsReceiptTables() {
        let html = """
        <table>
          <tr>
            <th>Item</th>
            <th>Quantity</th>
            <th>Amount</th>
          </tr>
          <tr>
            <td>Sample Cloud 50GB</td>
            <td>1</td>
            <td>&yen;130</td>
          </tr>
          <tr>
            <td>Total</td>
            <td></td>
            <td>&yen;130</td>
          </tr>
        </table>
        """

        let expected = """
        Item | Quantity | Amount
        Sample Cloud 50GB | 1 | ¥130
        Total | ¥130
        """
        #expect(HTMLText.plainText(html) == expected)
    }

    @Test("Handles nested layout tables without stray separators")
    func nestedLayoutTables() {
        let html = """
        <table>
          <tr>
            <td>
              <table>
                <tr><td>SAMPLE STORE</td><td>&yen;2,000</td></tr>
              </table>
            </td>
          </tr>
        </table>
        """
        #expect(HTMLText.plainText(html) == "SAMPLE STORE | ¥2,000")
    }

    @Test("Decodes named, decimal and hex entities without double-decoding")
    func decodesEntities() {
        let html = "<p>&amp; &lt; &gt; &quot; &apos; a&nbsp;&nbsp;b &yen;500 &copy; 2026 &#65; &#x3042; &amp;lt;</p>"
        #expect(HTMLText.plainText(html) == #"& < > " ' a b ¥500 © 2026 A あ &lt;"#)
    }

    @Test("Turns block elements into line breaks, collapses spaces and trims outer empty lines")
    func blockElementsAndWhitespace() {
        let html = """
        <br><br>
        <div>  Line   one\t\there  </div>
        <p>Line two<br/>Line three</p>
        <ul>
          <li>First item</li>
          <li>Second item</li>
        </ul>
        <h2>Summary</h2>
        <p>1 &lt; 2 and 3 < 4</p>
        <br>
        """

        let expected = """
        Line one here
        Line two
        Line three
        First item
        Second item
        Summary
        1 < 2 and 3 < 4
        """
        #expect(HTMLText.plainText(html) == expected)
    }

    @Test("Does not confuse header or custom head-prefixed tags with head")
    func doesNotSkipHeaderTag() {
        let html = "<header>Top Banner</header><p>Body</p>"
        #expect(HTMLText.plainText(html) == "Top Banner\nBody")
    }
}
