import AppKit

@MainActor
final class PluginSelectionAccessoryView: NSView {
    private let plugins: [HarnessPlugin]
    private let selectAllButton: NSButton
    private var pluginButtons: [NSButton] = []

    init(plugins: [HarnessPlugin]) {
        self.plugins = plugins
        selectAllButton = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 1))
        translatesAutoresizingMaskIntoConstraints = false

        selectAllButton.target = self
        selectAllButton.action = #selector(toggleAll)
        selectAllButton.allowsMixedState = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
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

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let contentHeight = CGFloat(34 + max(plugins.count, 1) * 24)
        frame.size.height = min(max(contentHeight, 72), 280)
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
