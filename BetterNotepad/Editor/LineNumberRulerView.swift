import AppKit

/// Line-number gutter for a TextKit 2 text view. Only the visible layout fragments are
/// enumerated, so drawing cost does not depend on document size.
final class LineNumberRulerView: NSRulerView {
    weak var textView: NotepadTextView?
    let lineIndex: LineIndex

    var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) {
        didSet {
            updateThickness(force: true)
            needsDisplay = true
        }
    }

    private var lastDigits = 0

    init(scrollView: NSScrollView, textView: NotepadTextView, lineIndex: LineIndex) {
        self.textView = textView
        self.lineIndex = lineIndex
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // Since macOS 14 views don't clip to their bounds by default; without this the
        // gutter's background fill can paint over the text view next to it.
        clipsToBounds = true
        updateThickness(force: true)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }

    func updateThickness(force: Bool = false) {
        let digits = max(3, String(lineIndex.lineCount).count)
        guard force || digits != lastDigits else { return }
        lastDigits = digits
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(digitWidth * CGFloat(digits) + 22)
        if abs(thickness - ruleThickness) > 0.5 {
            ruleThickness = thickness
            scrollView?.tile()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = dirtyRect.intersection(bounds)
        guard !rect.isEmpty else { return }
        Theme.editorBackground.setFill()
        rect.fill()
        drawHashMarksAndLabels(in: rect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
              let storage = tv.textStorage else { return }

        let origin = tv.textContainerOrigin
        let visible = tv.visibleRect
        let docStart = tcm.documentRange.location
        let length = storage.length
        let caretLine = lineIndex.lineNumber(at: min(tv.selectedRange().location, length))

        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.gutterText]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let editorFont = tv.font ?? font
        let defaultLineHeight = ceil(editorFont.ascender - editorFont.descender + editorFont.leading)

        func drawNumber(_ line: Int, textViewY: CGFloat, lineHeight: CGFloat) {
            let label = String(line + 1) as NSString
            let attrs = line == caretLine ? current : normal
            let size = label.size(withAttributes: attrs)
            let y = convert(NSPoint(x: 0, y: textViewY), from: tv).y
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y + (lineHeight - size.height) / 2),
                       withAttributes: attrs)
        }

        if length == 0 {
            drawNumber(0, textViewY: origin.y, lineHeight: defaultLineHeight)
            return
        }

        let startPoint = CGPoint(x: 0, y: max(0, visible.minY - origin.y))
        let startLocation = tlm.textLayoutFragment(for: startPoint)?.rangeInElement.location
            ?? tlm.textViewportLayoutController.viewportRange?.location
            ?? docStart

        var lastFragment: NSTextLayoutFragment?
        var lastFragmentOffset = 0
        var reachedEnd = true

        tlm.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let top = frame.minY + origin.y
            if top > visible.maxY {
                reachedEnd = false
                return false
            }
            let offset = tcm.offset(from: docStart, to: fragment.rangeInElement.location)
            var lineHeight = frame.height
            var lineTop: CGFloat = 0
            if let first = fragment.textLineFragments.first {
                lineHeight = first.typographicBounds.height
                lineTop = first.typographicBounds.minY
            }
            drawNumber(self.lineIndex.lineNumber(at: offset), textViewY: top + lineTop, lineHeight: lineHeight)
            lastFragment = fragment
            lastFragmentOffset = offset
            return true
        }

        // The empty last line after a trailing newline has no paragraph of its own.
        if reachedEnd, let last = lastFragment, lastFragmentOffset < length,
           storage.mutableString.character(at: length - 1) == 10 {
            let frame = last.layoutFragmentFrame
            var y = frame.maxY + origin.y
            var lineHeight = defaultLineHeight
            let lines = last.textLineFragments
            if lines.count > 1, let extra = lines.last, extra.characterRange.length == 0 {
                y = frame.minY + origin.y + extra.typographicBounds.minY
                lineHeight = extra.typographicBounds.height
            }
            drawNumber(lineIndex.lineCount - 1, textViewY: y, lineHeight: lineHeight)
        }
    }

    // Clicking/dragging in the gutter selects whole lines.
    override func mouseDown(with event: NSEvent) {
        textView?.trackLineSelection(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
