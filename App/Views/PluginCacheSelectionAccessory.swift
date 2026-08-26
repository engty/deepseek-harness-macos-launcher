import AppKit

@MainActor
final class PluginCacheSelectionAccessoryView: NSView {
    private let entries: [PluginCacheEntry]
    private let selectAllButton: NSButton
    private var entryButtons: [NSButton] = []

    init(entries: [PluginCacheEntry]) {
        self.entries = entries
        selectAllButton = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
        let contentHeight = CGFloat(34 + max(entries.count, 1) * 26)
        let accessoryHeight = min(max(contentHeight, 80), 300)
        super.init(frame: NSRect(x: 0, y: 0, width: 430, height: accessoryHeight))

        selectAllButton.target = self
        selectAllButton.action = #selector(toggleAll)
        selectAllButton.allowsMixedState = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(selectAllButton)
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)

        for entry in entries {
            let button = NSButton(
                checkboxWithTitle: "(entry.title)  ·  (Self.byteText(entry.sizeBytes))",
                target: self,
                action: #selector(entrySelectionChanged(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier(entry.id)
            entryButtons.append(button)
            stack.addArrangedSubview(button)
        }

        let scrollView = NSScrollView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        stack.frame = NSRect(x: 0, y: 0, width: bounds.width - 12, height: contentHeight)
        stack.autoresizingMask = [.width]
        scrollView.documentView = stack
        addSubview(scrollView)
        updateSelectAllState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var selectedEntries: [PluginCacheEntry] {
        zip(entries, entryButtons)
            .filter { $0.1.state == .on }
            .map { $0.0 }
    }

    @objc private func toggleAll() {
        let nextState: NSControl.StateValue = selectAllButton.state == .on ? .off : .on
        entryButtons.forEach { $0.state = nextState }
        updateSelectAllState()
    }

    @objc private func entrySelectionChanged(_ sender: NSButton) {
        updateSelectAllState()
    }

    private func updateSelectAllState() {
        let selectedCount = entryButtons.filter { $0.state == .on }.count
        if selectedCount == 0 {
            selectAllButton.state = .off
        } else if selectedCount == entryButtons.count {
            selectAllButton.state = .on
        } else {
            selectAllButton.state = .mixed
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
