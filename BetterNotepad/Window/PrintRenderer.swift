import AppKit

/// Prints a tab's text: always wrapped to the page, black on white, in the editor font at 100%,
/// with the tab name, date and page numbers in the header and footer.
@MainActor
enum PrintRenderer {
    static func operation(text: String, title: String, font: NSFont, markdown: Bool = false) -> NSPrintOperation {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true

        let pageWidth = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = PrintTextView(usingTextLayoutManager: false)   // TextKit 1 paginates without splitting lines
        view.jobTitle = title
        view.frame = NSRect(x: 0, y: 0, width: pageWidth, height: 100)
        view.appearance = NSAppearance(named: .aqua)
        view.isEditable = false
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: pageWidth, height: .greatestFiniteMagnitude)

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 4
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]))
        if markdown, let storage = view.textStorage, storage.length <= MarkdownStyler.maxStyledLength {
            // Same formatting as on screen; colours resolve for the light page (view appearance is Aqua).
            MarkdownStyler.style(storage, range: NSRange(location: 0, length: storage.length), base: font, paragraph: paragraph)
        }
        if let manager = view.layoutManager, let container = view.textContainer {
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            view.frame.size.height = max(used.height, 1)
        }

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.insert([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        return operation
    }
}

private final class PrintTextView: NSTextView {
    var jobTitle = "Untitled"
    override var printJobTitle: String { jobTitle }
}
