import AppKit
import PaneSwitchCore

/// An NSSearchField at its public boundary, with a private, attachment-aware field editor.
/// Attachments occupy one UTF-16 position; their trailing visual padding is not a character.
@MainActor
final class HostFilterSearchField: NSSearchField, NSTableViewDataSource, NSTableViewDelegate {
    private var query = ""
    private var hosts: [RexHost] = []
    private var foldedLabels: [String] = []
    private var matches: [Int] = []
    private var completion: HostCompletion?
    private var selectedSuggestion = 0
    private var updating = false
    private var suggestionPanel: NSPanel?
    private var suggestionTable: NSTableView?
    private var suggestionScroll: NSScrollView?
    private let hostEditor = HostFilterEditor(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEditor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installEditor()
    }

    private func installEditor() {
        let replacement = HostFilterSearchCell(textCell: "")
        replacement.hostEditor = hostEditor
        cell = replacement
        isEditable = true
        isSelectable = true
        allowsEditingTextAttributes = true
        hostEditor.hostField = self
        hostEditor.isFieldEditor = true
        hostEditor.isRichText = true
        hostEditor.importsGraphics = false
        hostEditor.allowsUndo = true
        hostEditor.isAutomaticQuoteSubstitutionEnabled = false
        hostEditor.isAutomaticDashSubstitutionEnabled = false
        hostEditor.isAutomaticTextReplacementEnabled = false
        hostEditor.isContinuousSpellCheckingEnabled = false
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
            name: NSTextView.didChangeSelectionNotification, object: hostEditor)
    }

    override var stringValue: String {
        get { query }
        set {
            guard newValue != query else { return }
            dismissHostSuggestions()
            query = newValue
            updating = true
            let document = HostQueryDocument.attributed(newValue, font: font ?? .systemFont(ofSize: 15))
            super.attributedStringValue = document
            if currentEditor() === hostEditor {
                hostEditor.textStorage?.setAttributedString(document)
                hostEditor.setSelectedRange(NSRange(location: document.length, length: 0))
            }
            updating = false
        }
    }

    override func accessibilityValue() -> String? { query }

    func setHosts(_ values: [RexHost]) {
        guard hosts != values else { return }
        hosts = values
        foldedLabels = values.map { Self.fold($0.label) }
        let previous = completion
        completion = nil
        if previous != nil { updateSuggestions() }
    }

    func deleteToLineStart() {
        guard isEnabled else { return }
        if currentEditor() !== hostEditor { window?.makeFirstResponder(self) }
        guard currentEditor() === hostEditor, !hostEditor.hasMarkedText() else { return }
        dismissHostSuggestions()
        hostEditor.deleteToBeginningOfLine(nil)
    }

    func deletePreviousWord() {
        guard isEnabled else { return }
        if currentEditor() !== hostEditor { window?.makeFirstResponder(self) }
        guard currentEditor() === hostEditor, !hostEditor.hasMarkedText() else { return }
        dismissHostSuggestions()
        hostEditor.deleteWordBackward(nil)
    }

    /// Consult this before the picker's Enter, arrows, and Escape handlers.
    /// Command shortcuts and marked-text input always retain their native routing.
    func handleSuggestionKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let controlNavigation = modifiers == .control && (event.keyCode == 38 || event.keyCode == 40)
        guard !hostEditor.hasMarkedText(),
              (modifiers.intersection([.command, .control, .option]).isEmpty || controlNavigation),
              completion != nil else { return false }
        let keyCode: UInt16 = controlNavigation ? (event.keyCode == 38 ? 125 : 126) : event.keyCode
        switch keyCode {
        case 48, 125, 126:
            if !matches.isEmpty {
                let backwards = keyCode == 126 ||
                    (event.keyCode == 48 && event.modifierFlags.contains(.shift))
                selectedSuggestion = (selectedSuggestion + (backwards ? matches.count - 1 : 1)) % matches.count
                selectSuggestionRow()
            }
        case 36, 76:
            acceptSuggestion()
        default:
            return false
        }
        return true
    }

    func dismissHostSuggestions() {
        completion = nil
        suggestionPanel?.orderOut(nil)
    }

    override func textDidChange(_ notification: Notification) {
        guard !updating else { return }
        if !hostEditor.hasMarkedText(), hostEditor.undoManager?.isUndoing != true,
           hostEditor.undoManager?.isRedoing != true { tokenizeFinishedOperators() }
        let value = HostQueryDocument.serialize(hostEditor.attributedString())
        let changed = value != query
        query = value
        if changed { super.textDidChange(notification) }
        updateSuggestions()
    }

    override func textDidEndEditing(_ notification: Notification) {
        dismissHostSuggestions()
        super.textDidEndEditing(notification)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { dismissHostSuggestions() }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func selectionChanged(_ notification: Notification) {
        guard !updating, currentEditor() === hostEditor else { return }
        updateSuggestions()
    }

    fileprivate func editorBeganEditing() {
        hostEditor.isRichText = true
        hostEditor.importsGraphics = false
        hostEditor.typingAttributes = textAttributes
        hostEditor.setAccessibilityLabel(accessibilityLabel() ?? "Search Rex panes")
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? .systemFont(ofSize: 15), .foregroundColor: textColor ?? .labelColor]
    }

    private func tokenizeFinishedOperators() {
        guard let storage = hostEditor.textStorage else { return }
        let tokens = HostQueryDocument.tokens(in: storage.string)
        let selection = hostEditor.selectedRange()
        let applicable = tokens.filter {
            (($0.raw == "local:" || $0.raw == "remote:") && NSMaxRange($0.range) == selection.location) ||
                NSMaxRange($0.range) < selection.location ||
                (NSMaxRange(selection) < $0.range.location && NSMaxRange($0.range) < storage.length)
        }
        guard !applicable.isEmpty else { return }
        updating = true
        var mapped = selection
        for token in applicable.reversed() {
            let end = NSMaxRange(token.range)
            let replacement = HostQueryDocument.pill(token, font: font ?? .systemFont(ofSize: 15))
            guard hostEditor.shouldChangeText(in: token.range, replacementString: replacement.string) else { continue }
            storage.replaceCharacters(in: token.range, with: replacement)
            func map(_ position: Int) -> Int {
                if position >= end { return position - token.range.length + 1 }
                if position > token.range.location { return token.range.location + 1 }
                return position
            }
            let start = map(mapped.location)
            mapped = NSRange(location: start, length: max(0, map(NSMaxRange(mapped)) - start))
        }
        hostEditor.setSelectedRange(mapped)
        hostEditor.typingAttributes = textAttributes
        hostEditor.didChangeText()
        updating = false
    }

    private func updateSuggestions() {
        guard !updating, !hostEditor.hasMarkedText(), currentEditor() === hostEditor,
              let next = HostQueryDocument.completion(in: hostEditor.string,
                                                     selection: hostEditor.selectedRange()) else {
            dismissHostSuggestions()
            return
        }
        if next != completion {
            completion = next
            let needle = Self.fold(next.fragment)
            matches = foldedLabels.indices.filter { needle.isEmpty || foldedLabels[$0].contains(needle) }
            selectedSuggestion = 0
            if let table = suggestionTable { table.reloadData(); selectSuggestionRow() }
        }
        showSuggestions()
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func makeSuggestionPanel() {
        guard suggestionPanel == nil else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        panel.contentView = background
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host-completion"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clickedSuggestion)
        table.setAccessibilityLabel("Host suggestions. Tab, arrows, or Control J and Control K to choose, Return to accept, Escape to close the picker.")
        scroll.documentView = table
        background.addSubview(scroll)
        suggestionPanel = panel
        suggestionTable = table
        suggestionScroll = scroll
        table.reloadData()
        selectSuggestionRow()
    }

    private func showSuggestions() {
        guard let window, window.isVisible, completion != nil else { return }
        makeSuggestionPanel()
        guard let panel = suggestionPanel else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let font = NSFont.systemFont(ofSize: 13)
        let labels = matches.isEmpty ? ["No matching hosts"] : matches.map { hosts[$0].label }
        let labelWidth = labels.reduce(CGFloat.zero) {
            max($0, ($1 as NSString).size(withAttributes: [.font: font]).width)
        }
        let width = min(max(ceil(labelWidth) + 40, 140), min(360, window.screen?.visibleFrame.width ?? 360))
        let height = CGFloat(max(1, min(matches.count, 7))) * 26 + 8
        var frame = NSRect(x: anchor.minX + 20, y: anchor.minY - height - 3, width: width, height: height)
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - width))
            if frame.minY < visible.minY { frame.origin.y = anchor.maxY + 3 }
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            suggestionScroll?.frame = NSRect(x: 4, y: 4, width: width - 8, height: height - 8)
            suggestionTable?.tableColumns.first?.width = width - 8
        }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    private func selectSuggestionRow() {
        guard !matches.isEmpty else {
            suggestionTable?.deselectAll(nil)
            return
        }
        suggestionTable?.selectRowIndexes(IndexSet(integer: selectedSuggestion), byExtendingSelection: false)
        suggestionTable?.scrollRowToVisible(selectedSuggestion)
    }

    @objc private func clickedSuggestion() {
        guard let table = suggestionTable, table.clickedRow >= 0, !matches.isEmpty else { return }
        selectedSuggestion = table.clickedRow
        acceptSuggestion()
        window?.makeFirstResponder(hostEditor)
    }

    private func acceptSuggestion() {
        guard let completion, matches.indices.contains(selectedSuggestion),
              let storage = hostEditor.textStorage else { return }
        let label = hosts[matches[selectedSuggestion]].label
        let token = HostQueryToken(range: completion.range, label: label,
                                   raw: HostQueryDocument.operatorText(label))
        let replacement = HostQueryDocument.pill(token, font: font ?? .systemFont(ofSize: 15))
        guard hostEditor.shouldChangeText(in: completion.range, replacementString: replacement.string) else { return }
        updating = true
        storage.replaceCharacters(in: completion.range, with: replacement)
        hostEditor.setSelectedRange(NSRange(location: completion.range.location + 1, length: 0))
        hostEditor.typingAttributes = textAttributes
        updating = false
        dismissHostSuggestions()
        hostEditor.didChangeText()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { max(1, matches.count) }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !matches.isEmpty }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HostSuggestionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("host-suggestion")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.alignment = .left
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        guard let label = cell.textField else { return cell }
        label.stringValue = matches.isEmpty ? "No matching hosts" : hosts[matches[row]].label
        label.textColor = matches.isEmpty ? .secondaryLabelColor : .labelColor
        label.setAccessibilityLabel(label.stringValue)
        return cell
    }
}

@MainActor
private final class HostSuggestionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

@MainActor
private final class HostFilterSearchCell: NSSearchFieldCell {
    weak var hostEditor: HostFilterEditor?

    // Accessibility focus resolution also looks up the editor. Configure it only
    // during editing setup; changing its accessibility label here breaks that query.
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        return hostEditor
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        if let editor = editor as? NSTextView {
            editor.isRichText = true
            editor.importsGraphics = false
        }
        hostEditor?.hostField?.editorBeganEditing()
        return editor
    }
}

@MainActor
private final class HostFilterEditor: NSTextView {
    weak var hostField: HostFilterSearchField?

    @objc func undo(_ sender: Any?) {
        guard let undoManager, undoManager.canUndo else { return }
        undoManager.undo()
        didChangeText()
    }

    @objc func redo(_ sender: Any?) {
        guard let undoManager, undoManager.canRedo else { return }
        undoManager.redo()
        didChangeText()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return undoManager?.canUndo == true
        case #selector(redo(_:)): return undoManager?.canRedo == true
        default: return super.validateUserInterfaceItem(item)
        }
    }

    override func keyDown(with event: NSEvent) {
        if hostField?.handleSuggestionKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // Never inherit an attachment attribute into subsequent ordinary typing or IME input.
        typingAttributes.removeValue(forKey: .attachment)
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let text = pboard.string(forType: .string) else { return false }
        let document = HostQueryDocument.attributed(text, font: hostField?.font ?? font ?? .systemFont(ofSize: 15))
        insertText(document, replacementRange: selectedRange())
        return true
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let range = selectedRange()
        guard type == .string, range.length > 0 else { return false }
        let text = HostQueryDocument.serialize(attributedString().attributedSubstring(from: range))
        return pboard.setString(text, forType: .string)
    }
}

private struct HostQueryToken {
    let range: NSRange
    let label: String
    let raw: String
}

private struct HostCompletion: Equatable {
    let range: NSRange
    let fragment: String
}

/// All positions here are NSString/NSTextView UTF-16 positions, never Swift character offsets.
@MainActor
private enum HostQueryDocument {
    static func operatorText(_ label: String) -> String {
        if label.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) {
            return "host:\"" + label.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "host:" + label
    }

    static func attributed(_ raw: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: raw, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        for token in tokens(in: raw).reversed() {
            result.replaceCharacters(in: token.range, with: pill(token, font: font))
        }
        return result
    }

    static func pill(_ token: HostQueryToken, font: NSFont) -> NSAttributedString {
        let attachment = HostPillAttachment(label: token.label, raw: token.raw, font: font)
        return NSAttributedString(attachment: attachment)
    }

    static func serialize(_ document: NSAttributedString) -> String {
        guard document.length > 0 else { return "" }
        var result = ""
        var previousWasPill = false
        document.enumerateAttributes(in: NSRange(location: 0, length: document.length)) { attributes, range, _ in
            if let pill = attributes[.attachment] as? HostPillAttachment {
                if let last = result.last, !last.isWhitespace { result.append(" ") }
                result += pill.raw
                previousWasPill = true
            } else {
                let text = (document.string as NSString).substring(with: range)
                if previousWasPill, let first = text.first, !first.isWhitespace { result.append(" ") }
                result += text
                previousWasPill = false
            }
        }
        return result
    }

    static func tokens(in text: String) -> [HostQueryToken] {
        let source = text as NSString
        var result: [HostQueryToken] = []
        var position = 0
        while position < source.length {
            if whitespace(source.character(at: position)) || source.character(at: position) == 0xFFFC {
                position += 1
                continue
            }
            let start = position
            while position < source.length, !whitespace(source.character(at: position)), source.character(at: position) != 0xFFFC {
                position += 1
            }
            let word = source.substring(with: NSRange(location: start, length: position - start)).lowercased()
            if let prefix = ["local:", "remote:", "l:", "r:"].first(where: { word.hasPrefix($0) }),
               start + prefix.utf16.count == source.length || source.character(at: start + prefix.utf16.count) != 34 {
                let location = prefix == "l:" ? "local:" : prefix == "r:" ? "remote:" : prefix
                result.append(HostQueryToken(range: NSRange(location: start, length: prefix.utf16.count),
                                             label: location, raw: location))
                continue
            }
            if let quotedStart = locationValueStart(source, start: start, wordEnd: position),
               let quoted = quotedValue(source, start: quotedStart, limit: source.length) {
                position = quoted.end
                continue
            }
            guard let length = hostPrefixLength(source, start: start, end: position) else { continue }
            let valueStart = start + length
            var end = position
            var label: String
            if valueStart < source.length, source.character(at: valueStart) == 34 {
                guard let quoted = quotedValue(source, start: valueStart, limit: source.length),
                      quoted.end == source.length || whitespace(source.character(at: quoted.end)) || source.character(at: quoted.end) == 0xFFFC else { continue }
                label = quoted.text
                end = quoted.end
                position = end
            } else {
                label = source.substring(with: NSRange(location: valueStart, length: end - valueStart))
            }
            guard !label.isEmpty else { continue }
            let range = NSRange(location: start, length: end - start)
            result.append(HostQueryToken(range: range, label: label, raw: source.substring(with: range)))
        }
        return result
    }

    static func completion(in text: String, selection: NSRange) -> HostCompletion? {
        let source = text as NSString
        guard selection.length == 0, selection.location <= source.length else { return nil }
        let caret = selection.location
        var start = 0
        while start < caret {
            if whitespace(source.character(at: start)) || source.character(at: start) == 0xFFFC { start += 1; continue }
            let wordStart = start
            while start < caret, !whitespace(source.character(at: start)), source.character(at: start) != 0xFFFC { start += 1 }
            if let quotedStart = locationValueStart(source, start: wordStart, wordEnd: start) {
                guard let quoted = quotedValue(source, start: quotedStart, limit: source.length),
                      quoted.end < caret else { return nil }
                start = quoted.end
                continue
            }
            if let length = hostPrefixLength(source, start: wordStart, end: start) {
                let valueStart = wordStart + length
                if valueStart < caret, source.character(at: valueStart) == 34 {
                    if let closed = quotedValue(source, start: valueStart, limit: caret) {
                        if closed.end < caret { start = closed.end; continue }
                        return nil
                    }
                    let fragment = unescape(source.substring(with: NSRange(location: valueStart + 1, length: caret - valueStart - 1)))
                    let end = quotedValue(source, start: valueStart, limit: source.length)?.end ?? caret
                    return HostCompletion(range: NSRange(location: wordStart, length: end - wordStart), fragment: fragment)
                }
                if start == caret {
                    // Replace the whole current value when the caret sits in its middle.
                    var end = caret
                    while end < source.length, !whitespace(source.character(at: end)), source.character(at: end) != 0xFFFC { end += 1 }
                    return HostCompletion(range: NSRange(location: wordStart, length: end - wordStart),
                        fragment: source.substring(with: NSRange(location: valueStart, length: caret - valueStart)))
                }
            }
        }
        return nil
    }

    private static func hostPrefixLength(_ source: NSString, start: Int, end: Int) -> Int? {
        for prefix in ["host:", "h:"] where end - start >= prefix.utf16.count {
            if source.substring(with: NSRange(location: start, length: prefix.utf16.count)).lowercased() == prefix {
                return prefix.utf16.count
            }
        }
        return nil
    }

    private static func locationValueStart(_ source: NSString, start: Int, wordEnd: Int) -> Int? {
        for prefix in ["local:", "remote:", "l:", "r:"] where wordEnd - start >= prefix.utf16.count {
            let length = prefix.utf16.count
            if source.substring(with: NSRange(location: start, length: length)).lowercased() == prefix,
               start + length < source.length, source.character(at: start + length) == 34 {
                return start + length
            }
        }
        return nil
    }

    private static func quotedValue(_ source: NSString, start: Int, limit: Int) -> (text: String, end: Int)? {
        var end = start + 1
        while end < limit {
            let unit = source.character(at: end)
            if unit == 92, end + 1 < limit,
               source.character(at: end + 1) == 34 || source.character(at: end + 1) == 92 {
                end += 2
            } else if unit == 34 {
                return (unescape(source.substring(with: NSRange(location: start + 1, length: end - start - 1))), end + 1)
            } else { end += 1 }
        }
        return nil
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                if character != "\"" && character != "\\" { result.append("\\") }
                result.append(character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func whitespace(_ unit: unichar) -> Bool {
        UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
}

@MainActor
private final class HostPillAttachment: NSTextAttachment {
    let raw: String

    init(label: String, raw: String, font: NSFont) {
        self.raw = raw
        super.init(data: nil, ofType: nil)
        let display = raw == "local:" || raw == "remote:" ? String(raw.dropLast()) : "host:" + label
        attachmentCell = HostPillCell(label: display, font: font)
    }

    required init?(coder: NSCoder) { return nil }
}

@MainActor
private final class HostPillCell: NSTextAttachmentCell {
    private let attributedTitle: NSAttributedString
    private let size: NSSize
    private let titleHeight: CGFloat

    init(label: String, font: NSFont) {
        let pillFont = NSFont.systemFont(ofSize: min(12, font.pointSize), weight: .medium)
        attributedTitle = NSAttributedString(string: label, attributes: [.font: pillFont, .foregroundColor: NSColor.labelColor])
        let measured = attributedTitle.size()
        titleHeight = measured.height
        size = NSSize(width: ceil(measured.width) + 18, height: ceil(measured.height) + 2)
        super.init(textCell: "")
        stringValue = "Filter: " + label
    }

    required init(coder: NSCoder) { fatalError("Host pills are created from the plain query") }

    override func cellSize() -> NSSize { size }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -3) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let pill = NSRect(x: cellFrame.minX, y: cellFrame.minY, width: cellFrame.width - 6, height: cellFrame.height)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let shape = NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5)
        NSColor.labelColor.withAlphaComponent(contrast ? 0.26 : 0.18).setFill()
        shape.fill()
        NSColor.labelColor.withAlphaComponent(contrast ? 0.45 : 0.25).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        attributedTitle.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + (pill.height - titleHeight) / 2))
    }
}
