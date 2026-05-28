// MARK: exteraGram — Android-format markdown for plugin descriptions
//
// Matches LocaleUtils.fullyFormatText + AndroidUtilities.replaceTags:
//   **text**        → bold
//   <b>text</b>     → bold
//   [text](url)     → tappable link (blue, underlined)
//   <br> / <br/>    → newline
//
// Nothing else is formatted — this is intentionally identical to the
// Android exteraGram plugin cell / install sheet rendering.

import UIKit
import SwiftUI

// MARK: - UIKit renderer

/// Converts plugin description text using Android exteraGram markdown rules.
public func egAndroidMarkdown(
    _ raw: String,
    font: UIFont,
    color: UIColor
) -> NSAttributedString {
    let boldDesc = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
    let boldFont = UIFont(descriptor: boldDesc, size: font.pointSize)

    // Pre-process HTML line breaks
    let text = raw
        .replacingOccurrences(of: "<br/>", with: "\n")
        .replacingOccurrences(of: "<br>",  with: "\n")

    let result = NSMutableAttributedString()
    let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    var i = text.startIndex
    var plainStart = text.startIndex

    func flush(to end: String.Index) {
        guard plainStart < end else { return }
        result.append(NSAttributedString(string: String(text[plainStart..<end]), attributes: base))
    }
    func span(_ r: Range<String.Index>, _ attrs: [NSAttributedString.Key: Any]) {
        guard r.lowerBound < r.upperBound else { return }
        result.append(NSAttributedString(string: String(text[r]), attributes: attrs))
    }

    while i < text.endIndex {
        let ch = text[i]
        let rest = text[i...]

        // [text](url)
        if ch == "[",
           let cb = text.range(of: "]", range: text.index(after: i)..<text.endIndex),
           cb.upperBound < text.endIndex, text[cb.upperBound] == "(",
           let cp = text.range(of: ")", range: text.index(after: cb.upperBound)..<text.endIndex) {
            flush(to: i)
            let linkText = String(text[text.index(after: i)..<cb.lowerBound])
            let urlStr   = String(text[text.index(after: cb.upperBound)..<cp.lowerBound])
            var la = base
            la[.foregroundColor] = UIColor.systemBlue
            la[.underlineStyle]  = NSUnderlineStyle.single.rawValue
            if let u = URL(string: urlStr) { la[.link] = u }
            result.append(NSAttributedString(string: linkText, attributes: la))
            i = cp.upperBound; plainStart = i; continue
        }

        // **bold**
        if rest.hasPrefix("**"),
           let after = text.index(i, offsetBy: 2, limitedBy: text.endIndex).flatMap({ $0 <= text.endIndex ? $0 : nil }),
           let cl = text.range(of: "**", range: after..<text.endIndex) {
            flush(to: i)
            span(after..<cl.lowerBound, [.font: boldFont, .foregroundColor: color])
            i = cl.upperBound; plainStart = i; continue
        }

        // <b>bold</b>
        if rest.hasPrefix("<b>"),
           let after = text.index(i, offsetBy: 3, limitedBy: text.endIndex).flatMap({ $0 <= text.endIndex ? $0 : nil }),
           let cl = text.range(of: "</b>", range: after..<text.endIndex) {
            flush(to: i)
            span(after..<cl.lowerBound, [.font: boldFont, .foregroundColor: color])
            i = cl.upperBound; plainStart = i; continue
        }

        i = text.index(after: i)
    }
    flush(to: text.endIndex)
    return result
}

// MARK: - SwiftUI wrapper

/// Renders plugin description text with Android-format markdown.
/// Backed by UILabel so it works on iOS 13+ and adapts to multiline.
public struct EGMarkdownText: UIViewRepresentable {
    public let text: String
    public let font: UIFont
    public let color: UIColor
    public let lineLimit: Int

    public init(_ text: String, font: UIFont, color: UIColor, lineLimit: Int = 0) {
        self.text     = text
        self.font     = font
        self.color    = color
        self.lineLimit = lineLimit
    }

    public func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    public func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.numberOfLines = lineLimit
        uiView.attributedText = egAndroidMarkdown(text, font: font, color: color)
    }
}
