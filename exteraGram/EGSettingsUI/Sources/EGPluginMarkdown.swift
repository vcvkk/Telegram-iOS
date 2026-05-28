// MARK: exteraGram — Android-format markdown for plugin descriptions
//
// Matches LocaleUtils.fullyFormatText pipeline (LocaleUtils.java):
//   https://… / http://…   → tappable link (NSDataDetector, same as formatWithURLs)
//   [text](url)             → tappable link, blue + underlined (parseMarkdownLinks)
//   @username               → tappable tg://resolve link (formatWithUsernames)
//   **text**                → bold (AndroidUtilities.replaceTags FLAG_TAG_BOLD)
//   <b>text</b>             → bold (AndroidUtilities.replaceTags FLAG_TAG_BOLD)
//   <br> / <br/>            → newline (AndroidUtilities.replaceTags FLAG_TAG_BR)

import UIKit
import SwiftUI

// MARK: - Core renderer

/// Converts plugin description text using Android exteraGram markdown rules.
public func egAndroidMarkdown(
    _ raw: String,
    font: UIFont,
    color: UIColor
) -> NSAttributedString {
    let boldDesc = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
    let boldFont = UIFont(descriptor: boldDesc, size: font.pointSize)

    // Pre-process HTML line breaks (replaceTags FLAG_TAG_BR)
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

    // Pass 1: scan for [text](url), **bold**, <b>bold</b>
    while i < text.endIndex {
        let ch = text[i]
        let rest = text[i...]

        // [text](url) — parseMarkdownLinks
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

        // **bold** — replaceTags FLAG_TAG_BOLD
        if rest.hasPrefix("**"),
           let after = text.index(i, offsetBy: 2, limitedBy: text.endIndex).flatMap({ $0 <= text.endIndex ? $0 : nil }),
           let cl = text.range(of: "**", range: after..<text.endIndex) {
            flush(to: i)
            span(after..<cl.lowerBound, [.font: boldFont, .foregroundColor: color])
            i = cl.upperBound; plainStart = i; continue
        }

        // <b>bold</b> — replaceTags FLAG_TAG_BOLD
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

    // Pass 2: auto-detect bare URLs not already marked as links (formatWithURLs)
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
        let fullNS = NSRange(result.string.startIndex..., in: result.string)
        detector.enumerateMatches(in: result.string, range: fullNS) { match, _, _ in
            guard let match = match, let url = match.url else { return }
            let range = match.range
            var alreadyLinked = false
            result.enumerateAttribute(.link, in: range, options: []) { val, _, stop in
                if val != nil { alreadyLinked = true; stop.pointee = true }
            }
            if !alreadyLinked {
                result.addAttribute(.link,           value: url,                                  range: range)
                result.addAttribute(.foregroundColor, value: UIColor.systemBlue,                  range: range)
                result.addAttribute(.underlineStyle,  value: NSUnderlineStyle.single.rawValue,    range: range)
            }
        }
    }

    // Pass 3: @username → tg://resolve?domain=username (formatWithUsernames)
    let str = result.string as NSString
    var searchRange = NSRange(location: 0, length: str.length)
    while searchRange.length > 0 {
        let atPos = str.range(of: "@", options: [], range: searchRange)
        guard atPos.location != NSNotFound else { break }
        var end = atPos.location + 1
        while end < str.length {
            let c = str.character(at: end)
            // a-z A-Z 0-9 _
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 {
                end += 1
            } else { break }
        }
        let usernameLen = end - (atPos.location + 1)
        if usernameLen > 0 {
            let mentionRange = NSRange(location: atPos.location, length: usernameLen + 1)
            var alreadyLinked = false
            result.enumerateAttribute(.link, in: mentionRange, options: []) { val, _, stop in
                if val != nil { alreadyLinked = true; stop.pointee = true }
            }
            if !alreadyLinked,
               let raw = str.substring(with: NSRange(location: atPos.location + 1, length: usernameLen))
                   .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "tg://resolve?domain=\(raw)") {
                result.addAttribute(.link,            value: url,                               range: mentionRange)
                result.addAttribute(.foregroundColor, value: UIColor.systemBlue,               range: mentionRange)
                result.addAttribute(.underlineStyle,  value: NSUnderlineStyle.single.rawValue, range: mentionRange)
            }
        }
        let next = atPos.location + max(usernameLen + 1, 1)
        searchRange = NSRange(location: next, length: max(0, str.length - next))
    }

    return result
}

// MARK: - SwiftUI wrapper

/// Renders plugin description text with Android-format markdown.
/// Backed by UITextView (isScrollEnabled=false) — correctly reports multiline height to SwiftUI.
public struct EGMarkdownText: UIViewRepresentable {
    public let text: String
    public let font: UIFont
    public let color: UIColor
    public let lineLimit: Int

    public init(_ text: String, font: UIFont, color: UIColor, lineLimit: Int = 0) {
        self.text      = text
        self.font      = font
        self.color     = color
        self.lineLimit = lineLimit
    }

    public func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable      = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.required,  for: .vertical)
        tv.setContentHuggingPriority(.defaultLow,              for: .horizontal)
        tv.setContentHuggingPriority(.required,                for: .vertical)
        return tv
    }

    public func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.textContainer.maximumNumberOfLines = lineLimit
        uiView.attributedText = egAndroidMarkdown(text, font: font, color: color)
    }
}
