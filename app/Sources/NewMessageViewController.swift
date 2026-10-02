import AppKit

/// "To:" picker for starting a conversation: search chats and contacts, or type
/// a phone number with country code.
final class NewMessageViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: Store
    private let onPick: (String) -> Void
    private let field = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var results: [Store.Person] = []
    private var numberRow: String?
    /// Set when embedded in the conversation pane instead of presented.
    var onCancel: (() -> Void)?

    init(store: Store, onPick: @escaping (String) -> Void) {
        self.store = store
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 420))
        view = v
        let to = NSTextField(labelWithString: "To:")
        to.font = .systemFont(ofSize: 14, weight: .medium)
        to.textColor = .secondaryLabelColor
        to.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Name or phone number"
        field.controlSize = .large
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed)
        field.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.rowHeight = 58
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pickSelected)
        table.action = #selector(pickClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let cancel = CircleAction(symbol: "xmark", tip: "Cancel New Message", size: 32) { [weak self] in self?.close() }
        cancel.translatesAutoresizingMaskIntoConstraints = false

        [to, field, cancel, status, scroll].forEach(v.addSubview)
        NSLayoutConstraint.activate([
            to.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            to.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: to.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -10),
            field.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            cancel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    @objc private func changed() { refresh() }

    private func refresh() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        results = store.people(matching: q)
        let digits = q.filter(\.isNumber)
        numberRow = digits.count >= 7 && q.allSatisfy({ $0.isNumber || "+ -()".contains($0) }) ? "+" + digits : nil
        status.stringValue = ""
        table.reloadData()
        if numberOfRows(in: table) > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count + (numberRow == nil ? 0 : 1) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("p")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PersonCell ?? PersonCell()
        cell.identifier = id
        if let n = numberRow, row == 0 {
            cell.configure(jid: "", name: "Message \(n)", subtitle: "Check if this number is on WhatsApp", isGroup: false, path: "-")
        } else {
            let p = results[row - (numberRow == nil ? 0 : 1)]
            cell.configure(jid: p.jid, name: p.name, subtitle: p.subtitle, isGroup: p.isGroup, path: store.avatar(p.jid))
        }
        return cell
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            pickSelected()
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let n = numberOfRows(in: table)
            guard n > 0 else { return true }
            let d = sel == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let next = min(max(0, table.selectedRow + d), n - 1)
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    @objc private func pickClicked() { if table.clickedRow >= 0 { pick(table.clickedRow) } }
    @objc private func pickSelected() { if table.selectedRow >= 0 { pick(table.selectedRow) } }

    private func pick(_ row: Int) {
        if let n = numberRow, row == 0 {
            status.stringValue = "Looking up \(n)…"
            let res = Core.shared.call("resolve", ["phone": n])
            if let jid = res["jid"] as? String {
                finish(jid)
            } else {
                status.stringValue = (res["error"] as? String) ?? "Couldn't find that number."
                status.textColor = .systemRed
            }
            return
        }
        let i = row - (numberRow == nil ? 0 : 1)
        guard i >= 0, i < results.count else { return }
        finish(results[i].jid)
    }

    private func finish(_ jid: String) {
        if presentingViewController != nil { dismiss(nil) }
        onPick(jid)
    }

    private func close() {
        if let onCancel { onCancel() } else { dismiss(nil) }
    }

    func focusField() { view.window?.makeFirstResponder(field) }
}

final class PersonCell: NSTableCellView {
    private let avatar = AvatarView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    private let name = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        [avatar, name, sub].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        avatar.frame = NSRect(x: 8, y: (bounds.height - 40) / 2, width: 40, height: 40)
        name.frame = NSRect(x: 60, y: bounds.height / 2 + 1, width: bounds.width - 68, height: 18)
        sub.frame = NSRect(x: 60, y: bounds.height / 2 - 18, width: bounds.width - 68, height: 16)
    }

    func configure(jid: String, name n: String, subtitle: String, isGroup: Bool, path: String) {
        name.stringValue = n
        sub.stringValue = subtitle
        if jid.isEmpty {
            avatar.image = NSImage(systemSymbolName: "phone.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 38, weight: .regular).applying(.init(paletteColors: [.white, Theme.accent])))
        } else {
            avatar.configure(jid: jid, name: n, isGroup: isGroup, path: path, px: 80)
        }
    }
}
