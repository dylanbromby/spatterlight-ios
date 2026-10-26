import UIKit

/// What every kind of Glk window view can do.
protocol GlkWindowView: UIView {
    var windowID: Int { get }
    var windowType: Int { get }
    var hints: GlkHintTable { get }
    /// Called at the end of each batch of operations, once the content is in place.
    func endBatch()
    func applyStyleSheet(_ sheet: GlkStyleSheet)
    func frameDidChange()
}

// MARK: - Text buffer

/// A scrolling window of story text.
final class GlkBufferView: UIView, GlkWindowView, UITextViewDelegate {
    let windowID: Int
    let windowType = Int(wintype_TextBuffer)
    let hints: GlkHintTable

    let textView: UITextView
    private var sheet: GlkStyleSheet
    private var needsSmartScroll = false
    /// Where the output of the latest turn starts.
    private var turnStart = 0
    private(set) var echo = true
    var linkRequested = false
    var onLink: ((Int) -> Void)?
    /// The space the input bar and keyboard take up at the bottom.
    var bottomInset: CGFloat = 0 { didSet { if oldValue != bottomInset { updateInsets(keepBottom: true) } } }
    var onUserScroll: (() -> Void)?
    var onScroll: (() -> Void)?

    init(id: Int, hints: GlkHintTable, sheet: GlkStyleSheet) {
        self.windowID = id
        self.hints = hints
        self.sheet = sheet
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        textView = UITextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)

        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.delegate = self
        textView.dataDetectorTypes = []
        textView.adjustsFontForContentSizeCategory = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.linkTextAttributes = [:]
        textView.isAccessibilityElement = true
        textView.accessibilityLabel = "Story"
        textView.accessibilityTraits = [.staticText]
        textView.layer.cornerCurve = .continuous
        addSubview(textView)
        applyColors()
        updateInsets(keepBottom: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    var storage: NSTextStorage { textView.textStorage }

    private func applyColors() {
        backgroundColor = sheet.colors.background
        textView.backgroundColor = sheet.colors.background
        textView.tintColor = sheet.colors.link
        textView.overrideUserInterfaceStyle = sheet.colors.isDark ? .dark : .light
    }

    func frameDidChange() {
        textView.frame = bounds
        updateInsets(keepBottom: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if textView.frame != bounds {
            let wasAtBottom = isAtBottom
            textView.frame = bounds
            updateInsets(keepBottom: wasAtBottom)
        }
    }

    private func updateInsets(keepBottom: Bool) {
        let margin = sheet.theme.margin
        textView.textContainerInset = UIEdgeInsets(top: 10, left: margin, bottom: 14, right: margin)
        textView.contentInset.bottom = bottomInset
        textView.verticalScrollIndicatorInsets.bottom = bottomInset
        if keepBottom { scrollToBottom(animated: false) }
    }

    var isAtBottom: Bool {
        let visibleBottom = textView.contentOffset.y + textView.bounds.height - textView.contentInset.bottom
        return visibleBottom >= textView.contentSize.height - 24
    }

    // MARK: Output

    func append(_ text: NSAttributedString) {
        guard text.length > 0 else { return }
        if !needsSmartScroll {
            needsSmartScroll = true
        }
        storage.beginEditing()
        storage.append(text)
        storage.endEditing()
        trimIfNeeded()
    }

    func unprint(units: Int) {
        let length = storage.length
        let count = min(units, length)
        guard count > 0 else { return }
        storage.deleteCharacters(in: NSRange(location: length - count, length: count))
    }

    func clear() {
        storage.deleteCharacters(in: NSRange(location: 0, length: storage.length))
        turnStart = 0
        textView.contentOffset = CGPoint(x: 0, y: -textView.adjustedContentInset.top)
    }

    func setEcho(_ value: Bool) { echo = value }

    /// Add what the player typed, as the interpreter would have echoed it.
    func echoInput(_ line: String, terminator: Bool = true) {
        guard echo else { return }
        let run = GlkRun(style: Int(style_Input), foreground: nil, background: nil, reverse: false)
        let attributes = sheet.attributes(for: run, windowType: windowType, hints: hints)
        let text = NSMutableAttributedString(string: line, attributes: attributes)
        let plain = sheet.attributes(for: GlkRun(style: Int(style_Normal), foreground: nil, background: nil, reverse: false),
                                     windowType: windowType, hints: hints)
        if terminator { text.append(NSAttributedString(string: "\n", attributes: plain)) }
        append(text)
    }

    /// The point where the newest output starts, noted when input is sent so that
    /// the next batch scrolls to show its beginning.
    func markTurnStart() { turnStart = storage.length }

    private func trimIfNeeded() {
        // Keep the text storage from growing without bound on very long sessions.
        let limit = 400_000
        guard storage.length > limit else { return }
        let cut = storage.length - limit / 2
        let ns = storage.string as NSString
        let newline = ns.range(of: "\n", options: [], range: NSRange(location: cut, length: min(2000, storage.length - cut)))
        let end = newline.location == NSNotFound ? cut : newline.location + 1
        storage.deleteCharacters(in: NSRange(location: 0, length: end))
        turnStart = max(0, turnStart - end)
    }

    // MARK: Images

    func insertImage(_ image: UIImage, alignment: Int, width: Int, height: Int, rule: UInt32, run: GlkRun) {
        let available = max(40, bounds.width - 2 * sheet.theme.margin)
        var size = CGSize(width: image.size.width, height: image.size.height)
        if let cg = image.cgImage { size = CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height)) }
        if width > 0 && height > 0 && rule == 0 {
            size = CGSize(width: width, height: height)
        } else if rule != 0 {
            let widthRule = rule & UInt32(imagerule_WidthMask)
            let heightRule = rule & UInt32(imagerule_HeightMask)
            var w = size.width, h = size.height
            if widthRule == UInt32(imagerule_WidthFixed) { w = CGFloat(width) }
            if heightRule == UInt32(imagerule_HeightFixed) { h = CGFloat(height) }
            else if heightRule == UInt32(imagerule_AspectRatio) { h = w * CGFloat(height) / 65536 }
            size = CGSize(width: w, height: h)
        }
        // Images are in screen pixels; on a phone they would be tiny or huge, so fit them.
        let scale = min(1, available / max(size.width, 1))
        let maxHeight = max(120, bounds.height * 0.6)
        var fitted = CGSize(width: size.width * scale, height: size.height * scale)
        if fitted.height > maxHeight {
            fitted = CGSize(width: fitted.width * maxHeight / fitted.height, height: maxHeight)
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.accessibilityLabel = "Illustration"
        attachment.bounds = CGRect(origin: .zero, size: fitted)
        let isMargin = alignment == Int(imagealign_MarginLeft) || alignment == Int(imagealign_MarginRight)
        let text = NSMutableAttributedString()
        let attributes = sheet.attributes(for: run, windowType: windowType, hints: hints)
        let atLineStart = storage.length == 0 || storage.string.hasSuffix("\n")
        if isMargin && !atLineStart { text.append(NSAttributedString(string: "\n", attributes: attributes)) }
        let imageString = NSMutableAttributedString(attachment: attachment)
        imageString.addAttributes([.glkRun: run], range: NSRange(location: 0, length: imageString.length))
        text.append(imageString)
        if isMargin { text.append(NSAttributedString(string: "\n", attributes: attributes)) }
        append(text)
    }

    // MARK: Scrolling

    func endBatch() {
        guard needsSmartScroll else { return }
        needsSmartScroll = false
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let contentHeight = textView.contentSize.height
        let visible = textView.bounds.height - textView.contentInset.bottom - textView.contentInset.top
        let start = min(turnStart, max(0, storage.length - 1))
        var startY = contentHeight
        if storage.length > 0 {
            let glyph = textView.layoutManager.glyphIndexForCharacter(at: start)
            let rect = textView.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            startY = rect.minY + textView.textContainerInset.top
        }
        let newHeight = contentHeight - startY
        if newHeight > visible * 0.92 {
            // Longer than the screen: start at the beginning of the new text.
            let y = max(-textView.adjustedContentInset.top, startY - 8 - textView.contentInset.top)
            textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        } else {
            scrollToBottom(animated: !UIAccessibility.isReduceMotionEnabled && bounds.width > 0)
        }
    }

    func scrollToBottom(animated: Bool) {
        textView.layoutIfNeeded()
        let y = max(-textView.adjustedContentInset.top,
                    textView.contentSize.height - textView.bounds.height + textView.contentInset.bottom)
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { onUserScroll?() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { onScroll?() }

    // MARK: Styles

    func applyStyleSheet(_ newSheet: GlkStyleSheet) {
        sheet = newSheet
        applyColors()
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.enumerateAttribute(.glkRun, in: full, options: []) { value, range, _ in
            guard let run = value as? GlkRun else { return }
            let link = (storage.attribute(.glkLink, at: range.location, effectiveRange: nil) as? Int) ?? 0
            let attributes = newSheet.attributes(for: run, windowType: windowType, hints: hints, link: link)
            // Leave images (attachments) alone: only text is restyled.
            if storage.attribute(.attachment, at: range.location, effectiveRange: nil) != nil { return }
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
        updateInsets(keepBottom: false)
    }

    // MARK: Links

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        guard URL.scheme == "glklink", let number = Int(URL.absoluteString.dropFirst("glklink:".count)) else { return true }
        if linkRequested { onLink?(number) }
        return false
    }

    func textViewDidChangeSelection(_ textView: UITextView) {}
}

// MARK: - Text grid

/// A grid of characters: the status line of a Z-code game, or a map.
final class GlkGridView: UIView, GlkWindowView {
    let windowID: Int
    let windowType = Int(wintype_TextGrid)
    let hints: GlkHintTable

    private var sheet: GlkStyleSheet
    private(set) var columns = 0
    private(set) var rows = 0
    private var lines: [NSMutableAttributedString] = []
    private var cursorColumn = 0
    private var cursorRow = 0
    var overrideBackground: UIColor?
    var mouseRequested = false
    var linkRequested = false
    var onMouse: ((Int, Int) -> Void)?
    var onLink: ((Int) -> Void)?
    private var transparent = false

    init(id: Int, hints: GlkHintTable, sheet: GlkStyleSheet) {
        self.windowID = id
        self.hints = hints
        self.sheet = sheet
        super.init(frame: .zero)
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = [.staticText]
        accessibilityLabel = "Status"
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var background: UIColor { overrideBackground ?? sheet.colors.gridBackground }

    func frameDidChange() { resizeGrid() }

    override func layoutSubviews() {
        super.layoutSubviews()
        resizeGrid()
    }

    private func resizeGrid() {
        let cell = sheet.gridCellSize
        let margin = sheet.theme.margin
        let newColumns = max(0, Int(((bounds.width - 2 * margin) / cell.width).rounded(.down)))
        let newRows = max(0, Int((bounds.height / cell.height).rounded(.down)))
        guard newColumns != columns || newRows != rows else { return }
        let old = lines
        columns = newColumns
        rows = newRows
        lines = (0..<rows).map { row in
            if row < old.count {
                let line = old[row]
                if line.length > columns { line.deleteCharacters(in: NSRange(location: columns, length: line.length - columns)) }
                else if line.length < columns { line.append(blank(count: columns - line.length)) }
                return line
            }
            return blank(count: columns)
        }
        cursorColumn = min(cursorColumn, max(0, columns))
        cursorRow = min(cursorRow, max(0, rows))
        setNeedsDisplay()
        updateAccessibility()
    }

    private func blank(count: Int) -> NSMutableAttributedString {
        let run = GlkRun(style: Int(style_Normal), foreground: nil, background: nil, reverse: false)
        return NSMutableAttributedString(string: String(repeating: " ", count: count),
                                         attributes: sheet.attributes(for: run, windowType: windowType, hints: hints))
    }

    func clear() {
        lines = (0..<rows).map { _ in blank(count: columns) }
        cursorColumn = 0
        cursorRow = 0
        setNeedsDisplay()
        updateAccessibility()
    }

    func moveTo(column: Int, row: Int) {
        cursorColumn = max(0, column)
        cursorRow = max(0, row)
    }

    func print(_ text: NSAttributedString) {
        guard rows > 0 else { return }
        let string = text.string as NSString
        var index = 0
        while index < string.length {
            let character = string.character(at: index)
            if character == 10 {
                cursorColumn = 0
                cursorRow += 1
                index += 1
                continue
            }
            if cursorColumn >= columns {
                cursorColumn = 0
                cursorRow += 1
            }
            if cursorRow >= rows { return }
            let piece = text.attributedSubstring(from: NSRange(location: index, length: 1))
            if cursorColumn < lines[cursorRow].length {
                lines[cursorRow].replaceCharacters(in: NSRange(location: cursorColumn, length: 1), with: piece)
            }
            cursorColumn += 1
            index += 1
        }
        setNeedsDisplay()
    }

    func endBatch() { updateAccessibility() }

    private func updateAccessibility() {
        accessibilityValue = lines.map { $0.string.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func makeTransparent() {
        transparent = true
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        if !transparent {
            context.setFillColor(background.cgColor)
            context.fill(bounds)
        }
        let cell = sheet.gridCellSize
        let margin = sheet.theme.margin
        for (row, line) in lines.enumerated() {
            let y = CGFloat(row) * cell.height
            if y > rect.maxY || y + cell.height < rect.minY { continue }
            // Draw each cell's background by hand so rows line up exactly.
            line.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: line.length), options: []) { value, range, _ in
                guard let color = value as? UIColor else { return }
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: margin + CGFloat(range.location) * cell.width, y: y,
                                    width: CGFloat(range.length) * cell.width, height: cell.height))
            }
            let foregroundOnly = NSMutableAttributedString(attributedString: line)
            foregroundOnly.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: foregroundOnly.length))
            // Draw character by character so the columns stay aligned even with a proportional font.
            var column = 0
            let count = foregroundOnly.length
            let font = sheet.gridBaseFont
            let baseline = (cell.height - font.lineHeight) / 2
            while column < count {
                let piece = foregroundOnly.attributedSubstring(from: NSRange(location: column, length: 1))
                if piece.string != " " {
                    piece.draw(at: CGPoint(x: margin + CGFloat(column) * cell.width, y: y + max(0, baseline)))
                }
                column += 1
            }
        }
    }

    func applyStyleSheet(_ newSheet: GlkStyleSheet) {
        sheet = newSheet
        // Restyle every cell from the run it was printed with.
        for line in lines {
            let full = NSRange(location: 0, length: line.length)
            line.enumerateAttribute(.glkRun, in: full, options: []) { value, range, _ in
                guard let run = value as? GlkRun else { return }
                let link = (line.attribute(.glkLink, at: range.location, effectiveRange: nil) as? Int) ?? 0
                line.setAttributes(newSheet.attributes(for: run, windowType: windowType, hints: hints, link: link), range: range)
            }
        }
        resizeGrid()
        setNeedsDisplay()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        let cell = sheet.gridCellSize
        let column = Int((point.x - sheet.theme.margin) / cell.width)
        let row = Int(point.y / cell.height)
        guard column >= 0, row >= 0, row < lines.count, column < lines[row].length else { return }
        if linkRequested, let link = lines[row].attribute(.glkLink, at: column, effectiveRange: nil) as? Int {
            onLink?(link)
        } else if mouseRequested {
            onMouse?(column, row)
        }
    }

    // MARK: Autosave

    func snapshot() -> [[SnapshotRun]] { lines.map { SnapshotRun.runs(from: $0) } }

    func restore(_ content: [[SnapshotRun]]) {
        resizeGrid()
        for (row, runs) in content.enumerated() where row < lines.count {
            lines[row] = SnapshotRun.attributedString(from: runs, sheet: sheet, windowType: windowType, hints: hints)
            if lines[row].length > columns { lines[row].deleteCharacters(in: NSRange(location: columns, length: lines[row].length - columns)) }
            if lines[row].length < columns { lines[row].append(blank(count: columns - lines[row].length)) }
        }
        setNeedsDisplay()
    }
}

// MARK: - Graphics

/// A window you can draw on: pictures and filled rectangles.
final class GlkGraphicsView: UIView, GlkWindowView {
    let windowID: Int
    let windowType = Int(wintype_Graphics)
    let hints: GlkHintTable

    private var sheet: GlkStyleSheet
    private var context: CGContext?
    private var pixelScale: CGFloat = UIScreen.main.scale
    private var backgroundValue: Int32 = -1
    var mouseRequested = false
    var onMouse: ((Int, Int) -> Void)?

    init(id: Int, hints: GlkHintTable, sheet: GlkStyleSheet) {
        self.windowID = id
        self.hints = hints
        self.sheet = sheet
        super.init(frame: .zero)
        layer.magnificationFilter = .nearest
        isOpaque = true
        isAccessibilityElement = true
        accessibilityTraits = [.image]
        accessibilityLabel = "Picture"
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        backgroundColor = sheet.colors.background
    }

    required init?(coder: NSCoder) { fatalError() }

    private var backgroundColorValue: UIColor {
        backgroundValue < 0 ? sheet.colors.background : GlkStyleSheet.color(UInt32(bitPattern: backgroundValue))
    }

    func frameDidChange() { resizeBitmap() }
    override func layoutSubviews() { super.layoutSubviews(); resizeBitmap() }

    private func resizeBitmap() {
        let width = Int((bounds.width * pixelScale).rounded()), height = Int((bounds.height * pixelScale).rounded())
        guard width > 0, height > 0 else { context = nil; layer.contents = nil; return }
        if let context = context, context.width == width, context.height == height { return }
        let old = context?.makeImage()
        guard let new = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        // Work in points with the origin at the top left.
        new.translateBy(x: 0, y: CGFloat(height))
        new.scaleBy(x: pixelScale, y: -pixelScale)
        new.setFillColor(backgroundColorValue.cgColor)
        new.fill(CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        if let old = old {
            new.saveGState()
            new.scaleBy(x: 1, y: -1)
            new.draw(old, in: CGRect(x: 0, y: -CGFloat(old.height) / pixelScale, width: CGFloat(old.width) / pixelScale, height: CGFloat(old.height) / pixelScale))
            new.restoreGState()
        }
        context = new
        present()
    }

    private func present() { layer.contents = context?.makeImage() }

    func fill(_ rects: [(color: UInt32, rect: CGRect)]) {
        guard let context = context else { return }
        for item in rects {
            let color: UIColor
            switch item.color {
            case zcolor_Default, zcolor_Current: color = backgroundColorValue
            default: color = GlkStyleSheet.color(item.color)
            }
            context.setFillColor(color.cgColor)
            context.fill(item.rect)
        }
        present()
    }

    func clear() {
        guard let context = context else { return }
        context.setFillColor(backgroundColorValue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        present()
    }

    func setBackground(_ color: Int32) {
        backgroundValue = color
        backgroundColor = backgroundColorValue
    }

    func draw(image: UIImage, x: Int, y: Int, width: Int, height: Int, rule: UInt32) {
        guard let context = context, let cg = image.cgImage else { return }
        var w = CGFloat(cg.width), h = CGFloat(cg.height)
        if rule != 0 {
            let widthRule = rule & UInt32(imagerule_WidthMask)
            let heightRule = rule & UInt32(imagerule_HeightMask)
            if widthRule == UInt32(imagerule_WidthFixed) { w = CGFloat(width) }
            else if widthRule == UInt32(imagerule_WidthRatio) { w = bounds.width * CGFloat(width) / 65536 }
            if heightRule == UInt32(imagerule_HeightFixed) { h = CGFloat(height) }
            else if heightRule == UInt32(imagerule_AspectRatio) { h = w * CGFloat(height) / 65536 }
            else { h = h * w / CGFloat(cg.width) }
        } else if width > 0 && height > 0 {
            w = CGFloat(width); h = CGFloat(height)
        }
        context.saveGState()
        context.interpolationQuality = .high
        // The context is flipped; flip locally so the picture is the right way up.
        context.translateBy(x: CGFloat(x), y: CGFloat(y) + h)
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        context.restoreGState()
        present()
    }

    func endBatch() {}
    func applyStyleSheet(_ newSheet: GlkStyleSheet) {
        sheet = newSheet
        if backgroundValue < 0 { backgroundColor = newSheet.colors.background }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard mouseRequested else { return }
        let point = gesture.location(in: self)
        onMouse?(Int(point.x), Int(point.y))
    }

    func snapshot() -> Data? {
        guard let image = context?.makeImage() else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    func restore(_ data: Data) {
        resizeBitmap()
        guard let context = context, let image = UIImage(data: data)?.cgImage else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        context.restoreGState()
        present()
    }
}

// MARK: - Autosave of the screen

/// A stretch of styled text, in a form that can be saved.
struct SnapshotRun: Codable {
    var text: String
    var style: Int
    var foreground: UInt32?
    var background: UInt32?
    var reverse: Bool
    var link: Int
    var imageData: Data?
    var imageSize: [Double]?

    static func runs(from string: NSAttributedString) -> [SnapshotRun] {
        var result: [SnapshotRun] = []
        string.enumerateAttribute(.glkRun, in: NSRange(location: 0, length: string.length), options: []) { value, range, _ in
            let run = (value as? GlkRun) ?? GlkRun(style: Int(style_Normal), foreground: nil, background: nil, reverse: false)
            let link = (string.attribute(.glkLink, at: range.location, effectiveRange: nil) as? Int) ?? 0
            if let attachment = string.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
               let image = attachment.image {
                result.append(SnapshotRun(text: "", style: run.style, foreground: nil, background: nil, reverse: false, link: link,
                                          imageData: image.pngData(),
                                          imageSize: [Double(attachment.bounds.width), Double(attachment.bounds.height)]))
                return
            }
            result.append(SnapshotRun(text: string.attributedSubstring(from: range).string, style: run.style,
                                      foreground: run.foreground, background: run.background, reverse: run.reverse,
                                      link: link, imageData: nil, imageSize: nil))
        }
        return result
    }

    static func attributedString(from runs: [SnapshotRun], sheet: GlkStyleSheet, windowType: Int, hints: GlkHintTable) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for item in runs {
            let run = GlkRun(style: item.style, foreground: item.foreground, background: item.background, reverse: item.reverse)
            let attributes = sheet.attributes(for: run, windowType: windowType, hints: hints, link: item.link)
            if let data = item.imageData, let image = UIImage(data: data) {
                let attachment = NSTextAttachment()
                attachment.image = image
        attachment.accessibilityLabel = "Illustration"
                if let size = item.imageSize, size.count == 2 { attachment.bounds = CGRect(x: 0, y: 0, width: size[0], height: size[1]) }
                let piece = NSMutableAttributedString(attachment: attachment)
                piece.addAttributes([.glkRun: run], range: NSRange(location: 0, length: piece.length))
                result.append(piece)
            } else {
                result.append(NSAttributedString(string: item.text, attributes: attributes))
            }
        }
        return result
    }
}
