import UIKit

extension NSAttributedString.Key {
    /// A `GlkRun`: what the interpreter asked for, kept so text can be styled
    /// again when the theme changes.
    static let glkRun = NSAttributedString.Key("SpatterlightGlkRun")
    /// The number of the hyperlink the text belongs to.
    static let glkLink = NSAttributedString.Key("SpatterlightGlkLink")
    /// Marks an inline image: the resource number.
    static let glkImage = NSAttributedString.Key("SpatterlightGlkImage")
}

/// The Glk style hints an interpreter has set, as the values it gave them.
/// One table for each of text buffers and text grids; indexed [style][hint].
struct GlkHintTable: Codable {
    var values: [[Int32?]] = Array(repeating: Array(repeating: nil, count: Int(stylehint_NUMHINTS)), count: Int(style_NUMSTYLES))

    subscript(style: Int, hint: Int) -> Int32? {
        get {
            guard style >= 0, style < values.count, hint >= 0, hint < Int(stylehint_NUMHINTS) else { return nil }
            return values[style][hint]
        }
        set {
            guard style >= 0, style < values.count, hint >= 0, hint < Int(stylehint_NUMHINTS) else { return }
            values[style][hint] = newValue
        }
    }
}

/// The settings that apply to one stretch of text.
final class GlkRun: NSObject {
    let style: Int
    /// 0xRRGGBB, or nil for the style's own colour
    let foreground: UInt32?
    let background: UInt32?
    let reverse: Bool

    init(style: Int, foreground: UInt32?, background: UInt32?, reverse: Bool) {
        self.style = style
        self.foreground = foreground
        self.background = background
        self.reverse = reverse
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? GlkRun else { return false }
        return style == other.style && foreground == other.foreground && background == other.background && reverse == other.reverse
    }

    override var hash: Int { style &* 31 &+ Int(foreground ?? 0) &* 7 &+ Int(background ?? 1) &+ (reverse ? 1 : 0) }
}

/// Turns Glk styles into fonts and colours. Immutable, so it can be used from
/// the interpreter's thread and the main thread alike.
final class GlkStyleSheet {
    let theme: ReaderTheme
    let colors: ReaderTheme.Colors
    let sizeScale: CGFloat

    let bufferBaseFont: UIFont
    let gridBaseFont: UIFont

    /// The size of a character cell in the text grid, in points.
    let gridCellSize: CGSize
    /// The average character size in a text buffer, which interpreters use to size windows.
    let bufferCellSize: CGSize

    init(theme: ReaderTheme, systemIsDark: Bool, contentSizeCategory: UIContentSizeCategory) {
        self.theme = theme
        self.colors = theme.colors(systemIsDark: systemIsDark)
        if theme.followsDynamicType {
            let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
            sizeScale = UIFontMetrics.default.scaledValue(for: 100, compatibleWith: traits) / 100
        } else {
            sizeScale = 1
        }
        bufferBaseFont = GlkStyleSheet.makeBodyFont(theme.bodyFont, size: theme.fontSize * sizeScale)
        gridBaseFont = GlkStyleSheet.makeFixedFont(theme.fixedFont, size: theme.gridFontSize * sizeScale)

        let gridWidth = ("0" as NSString).size(withAttributes: [.font: gridBaseFont]).width
        gridCellSize = CGSize(width: ceil(gridWidth * 100) / 100, height: ceil(gridBaseFont.lineHeight + theme.lineSpacing * 0.5))
        let bufferWidth = ("0" as NSString).size(withAttributes: [.font: bufferBaseFont]).width
        bufferCellSize = CGSize(width: ceil(bufferWidth * 100) / 100, height: ceil(bufferBaseFont.lineHeight + theme.lineSpacing))
    }

    // MARK: Fonts

    static func makeBodyFont(_ choice: ReaderTheme.BodyFont, size: CGFloat) -> UIFont {
        if let family = choice.postScriptFamily, let font = UIFont(name: family, size: size) {
            return font
        }
        let system = UIFont.systemFont(ofSize: size)
        if choice == .newYork, let descriptor = system.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return system
    }

    static func makeFixedFont(_ choice: ReaderTheme.FixedFont, size: CGFloat) -> UIFont {
        if let family = choice.family, let font = UIFont(name: family, size: size) {
            return font
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func font(base: UIFont, bold: Bool, italic: Bool, size: CGFloat?, proportionalOverride: Bool?, isGrid: Bool) -> UIFont {
        var font = base
        if let proportionalOverride = proportionalOverride {
            if proportionalOverride && isGrid {
                font = GlkStyleSheet.makeBodyFont(theme.bodyFont, size: base.pointSize)
            } else if !proportionalOverride && !isGrid {
                font = GlkStyleSheet.makeFixedFont(theme.fixedFont, size: theme.gridFontSize * sizeScale * base.pointSize / max(bufferBaseFont.pointSize, 1) * (bufferBaseFont.pointSize / max(gridBaseFont.pointSize, 1)))
            }
        }
        if let size = size {
            font = font.withSize(size)
        }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if traits != font.fontDescriptor.symbolicTraits, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return font
    }

    // MARK: Style → attributes

    /// The attributes for text in `run`, in a window of the given type.
    func attributes(for run: GlkRun, windowType: Int, hints: GlkHintTable, link: Int = 0) -> [NSAttributedString.Key: Any] {
        let isGrid = windowType == Int(wintype_TextGrid)
        let style = run.style
        let base = isGrid ? gridBaseFont : bufferBaseFont

        var bold = false, italic = false
        var sizeFactor: CGFloat = 1
        var mono = isGrid
        var color = isGrid ? colors.gridText : colors.text
        var background: UIColor? = nil
        var justification: NSTextAlignment = (theme.justify && !isGrid) ? .justified : .natural
        var indent: CGFloat = 0
        var firstLineIndent: CGFloat = 0

        switch style {
        case Int(style_Emphasized): italic = true
        case Int(style_Preformatted): mono = true
        case Int(style_Header): bold = true; sizeFactor = 1.35
        case Int(style_Subheader): bold = true; sizeFactor = 1.15
        case Int(style_Alert): bold = true
        case Int(style_Note): italic = true
        case Int(style_BlockQuote): italic = true; indent = 28
        case Int(style_Input):
            if theme.accentInput { color = colors.input }
        default: break
        }

        // Hints from the game override the defaults.
        var reverse = run.reverse
        var proportionalOverride: Bool? = mono && !isGrid ? false : nil
        if hints[style, Int(stylehint_Weight)] != nil || hints[style, Int(stylehint_Oblique)] != nil ||
            hints[style, Int(stylehint_Size)] != nil || hints[style, Int(stylehint_Proportional)] != nil {
            if let weight = hints[style, Int(stylehint_Weight)] { bold = weight > 0 }
            if let oblique = hints[style, Int(stylehint_Oblique)] { italic = oblique != 0 }
            if let size = hints[style, Int(stylehint_Size)] {
                // A change in points, as other Glk interpreters read it.
                sizeFactor = max(0.5, 1 + CGFloat(size) * 0.1)
            }
            if let prop = hints[style, Int(stylehint_Proportional)] {
                proportionalOverride = prop != 0
                mono = prop == 0
            }
        }
        if let value = hints[style, Int(stylehint_TextColor)] { color = GlkStyleSheet.color(UInt32(bitPattern: value)) }
        if let value = hints[style, Int(stylehint_BackColor)] { background = GlkStyleSheet.color(UInt32(bitPattern: value)) }
        if let value = hints[style, Int(stylehint_ReverseColor)], value != 0 { reverse = !reverse }
        if let value = hints[style, Int(stylehint_Justification)], !isGrid {
            switch UInt32(bitPattern: value) {
            case UInt32(stylehint_just_LeftRight): justification = .justified
            case UInt32(stylehint_just_Centered): justification = .center
            case UInt32(stylehint_just_RightFlush): justification = .right
            default: justification = .natural
            }
        }
        if let value = hints[style, Int(stylehint_Indentation)], !isGrid { indent = max(0, CGFloat(value) * bufferCellSize.width) }
        if let value = hints[style, Int(stylehint_ParaIndentation)], !isGrid { firstLineIndent = CGFloat(value) * bufferCellSize.width }

        if let fg = run.foreground { color = GlkStyleSheet.color(fg) }
        if let bg = run.background { background = GlkStyleSheet.color(bg) }

        if reverse {
            let defaultBackground = isGrid ? colors.gridBackground : colors.background
            let newColor = background ?? defaultBackground
            background = color
            color = newColor
        }

        var fontToUse = base
        if mono != isGrid {
            fontToUse = mono ? GlkStyleSheet.makeFixedFont(theme.fixedFont, size: bufferBaseFont.pointSize * 0.9)
                             : GlkStyleSheet.makeBodyFont(theme.bodyFont, size: gridBaseFont.pointSize)
        }
        let resolvedFont = font(base: fontToUse, bold: bold, italic: italic,
                                size: sizeFactor == 1 ? nil : fontToUse.pointSize * sizeFactor,
                                proportionalOverride: nil, isGrid: isGrid)
        _ = proportionalOverride

        var attributes: [NSAttributedString.Key: Any] = [
            .font: resolvedFont,
            .foregroundColor: color,
            .glkRun: run,
        ]
        if let background = background { attributes[.backgroundColor] = background }

        if !isGrid {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = theme.lineSpacing
            paragraph.alignment = justification
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = indent + firstLineIndent
            paragraph.tailIndent = indent > 0 ? -indent : 0
            attributes[.paragraphStyle] = paragraph
        }
        if link > 0 {
            attributes[.glkLink] = link
            attributes[.link] = URL(string: "glklink:\(link)")!
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = color.withAlphaComponent(0.5)
        }
        return attributes
    }

    static func color(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }

    static func integer(_ color: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt32(r * 255 + 0.5) << 16) | (UInt32(g * 255 + 0.5) << 8) | UInt32(b * 255 + 0.5)
    }

    /// The answer to a `glk_style_measure` question, if we have one.
    func measure(windowType: Int, style: Int, hint: Int, hints: GlkHintTable) -> Int32? {
        let isGrid = windowType == Int(wintype_TextGrid)
        let run = GlkRun(style: style, foreground: nil, background: nil, reverse: false)
        let attributes = self.attributes(for: run, windowType: windowType, hints: hints)
        guard let font = attributes[.font] as? UIFont else { return nil }
        let traits = font.fontDescriptor.symbolicTraits
        switch hint {
        case Int(stylehint_Weight): return traits.contains(.traitBold) ? 1 : 0
        case Int(stylehint_Oblique): return traits.contains(.traitItalic) ? 1 : 0
        case Int(stylehint_Proportional): return traits.contains(.traitMonoSpace) || isGrid ? 0 : 1
        case Int(stylehint_Size): return Int32(font.pointSize.rounded())
        case Int(stylehint_TextColor):
            if let color = attributes[.foregroundColor] as? UIColor { return Int32(bitPattern: GlkStyleSheet.integer(color)) }
        case Int(stylehint_BackColor):
            let color = (attributes[.backgroundColor] as? UIColor) ?? (isGrid ? colors.gridBackground : colors.background)
            return Int32(bitPattern: GlkStyleSheet.integer(color))
        default: break
        }
        return nil
    }
}
