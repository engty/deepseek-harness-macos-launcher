import AppKit

@MainActor
final class PluginSelectionAccessoryView: NSView {
    private let plugins: [HarnessPlugin]
    private let selectAllButton: NSButton
    private var pluginButtons: [NSButton] = []

    init(plugins: [HarnessPlugin]) {
        self.plugins = plugins
        selectAllButton = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
        let contentHeight = CGFloat(34 + max(plugins.count, 1) * 24)
        let accessoryHeight = min(max(contentHeight, 72), 280)
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: accessoryHeight))

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

        for plugin in plugins {
            let button = NSButton(
                checkboxWithTitle: "\(plugin.name)  ·  \(plugin.version)",
                target: self,
                action: #selector(pluginSelectionChanged(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier(plugin.id)
            button.toolTip = plugin.id
            pluginButtons.append(button)
            stack.addArrangedSubview(button)
        }

        // With many installed plugins the button list no longer fits the
        // fixed accessory height, so the stack lives inside a scroll view
        // and the accessory keeps a bounded height.
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

    var selectedPlugins: [HarnessPlugin] {
        zip(plugins, pluginButtons)
            .filter { $0.1.state == .on }
            .map(\.0)
    }

    @objc private func toggleAll() {
        let nextState: NSControl.StateValue = selectAllButton.state == .on ? .off : .on
        pluginButtons.forEach { $0.state = nextState }
        updateSelectAllState()
    }

    @objc private func pluginSelectionChanged(_ sender: NSButton) {
        updateSelectAllState()
    }

    private func updateSelectAllState() {
        let selectedCount = pluginButtons.filter { $0.state == .on }.count
        if selectedCount == 0 {
            selectAllButton.state = .off
        } else if selectedCount == pluginButtons.count {
            selectAllButton.state = .on
        } else {
            selectAllButton.state = .mixed
        }
    }
}
