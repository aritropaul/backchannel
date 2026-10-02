import AppKit

/// Shared frame for the attach menu's sheets: a title, the form, then Cancel and a
/// default button (Return) at the bottom right.
class FormSheetViewController: NSViewController {
    let stack = NSStackView()
    let primary = NSButton()
    private let titleText: String
    private let primaryTitle: String
    let width: CGFloat

    init(title: String, primary: String, width: CGFloat = 400) {
        titleText = title
        primaryTitle = primary
        self.width = width
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(14, after: title)
        buildForm()

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"
        cancel.controlSize = .large
        primary.title = primaryTitle
        primary.target = self
        primary.action = #selector(confirm)
        primary.keyEquivalent = "\r"
        primary.bezelStyle = .push
        primary.controlSize = .large
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, primary])
        buttons.spacing = 10
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(18, after: last) }
        stack.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = root
        validate()
    }

    /// Subclasses add their fields to `stack` here.
    func buildForm() {}
    /// Subclasses enable `primary` when the form can be sent.
    func validate() {}
    /// Subclasses send, then call `dismiss(nil)`.
    @objc func confirm() {}

    @objc func cancelSheet() { dismiss(nil) }

    func field(_ placeholder: String, font: NSFont = .systemFont(ofSize: 14)) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.font = font
        f.bezelStyle = .roundedBezel
        f.controlSize = .large
        f.lineBreakMode = .byTruncatingTail
        f.delegate = self as? NSTextFieldDelegate
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    /// Adds a view stretched to the form's width.
    func addWide(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }

    func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// "Label ........ [switch]" row.
    func switchRow(_ label: String, on: Bool) -> (NSView, NSSwitch) {
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 13)
        let s = NSSwitch()
        s.state = on ? .on : .off
        s.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [l, spacer, s])
        row.distribution = .fill
        return (row, s)
    }
}

// MARK: - Poll

/// New poll: a question, up to 12 options (a new field appears as you fill the last),
/// and whether people can pick more than one.
final class PollComposerViewController: FormSheetViewController, NSTextFieldDelegate {
    var onSend: ((String, [String], Bool) -> Void)?
    private var question: NSTextField!
    private let options = NSStackView()
    private var multi: NSSwitch!
    private static let maxOptions = 12

    init() { super.init(title: "New Poll", primary: "Send") }
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        question = field("Ask a question", font: .systemFont(ofSize: 14, weight: .medium))
        addWide(question)
        stack.setCustomSpacing(16, after: question)
        let label = caption("OPTIONS")
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(6, after: label)
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 6
        addWide(options)
        addOption()
        addOption()
        stack.setCustomSpacing(14, after: options)
        let (row, s) = switchRow("Allow multiple answers", on: true)
        multi = s
        addWide(row)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(question)
    }

    private func addOption() {
        let f = field("Option \(options.arrangedSubviews.count + 1)")
        options.addArrangedSubview(f)
        f.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
    }

    private var optionFields: [NSTextField] { options.arrangedSubviews.compactMap { $0 as? NSTextField } }

    func controlTextDidChange(_ obj: Notification) {
        // Typing in the last option opens another, up to WhatsApp's 12.
        if let last = optionFields.last, !last.stringValue.isEmpty, optionFields.count < Self.maxOptions {
            addOption()
        }
        validate()
    }

    private var filledOptions: [String] {
        var seen = Set<String>()
        return optionFields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    override func validate() {
        let q = question?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        primary.isEnabled = !q.isEmpty && filledOptions.count >= 2
    }

    override func confirm() {
        validate()
        guard primary.isEnabled else { NSSound.beep(); return }
        onSend?(question.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), filledOptions, multi.state == .on)
        dismiss(nil)
    }
}

// MARK: - Event

/// New event: name, when (with an optional end), where, details, and whether guests
/// may bring someone. WhatsApp's call-link option is left out: calling is off in WA.
final class EventComposerViewController: FormSheetViewController, NSTextFieldDelegate {
    struct Draft {
        let name: String
        let start: Date
        let end: Date?
        let location: String
        let desc: String
        let allowGuests: Bool
    }

    var onSend: ((Draft) -> Void)?
    private var name: NSTextField!
    private let start = NSDatePicker()
    private let end = NSDatePicker()
    private let hasEnd = NSButton(checkboxWithTitle: "End time", target: nil, action: nil)
    private var location: NSTextField!
    private var desc: NSTextField!
    private var guests: NSSwitch!

    init() { super.init(title: "New Event", primary: "Send") }
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        name = field("Event name", font: .systemFont(ofSize: 14, weight: .medium))
        addWide(name)
        stack.setCustomSpacing(16, after: name)

        // The next whole hour, as Calendar suggests.
        let cal = Calendar.current
        let nextHour = cal.date(bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600)) ?? Date()
        for p in [start, end] {
            p.datePickerStyle = .textFieldAndStepper
            p.datePickerElements = [.yearMonthDay, .hourMinute]
            p.controlSize = .large
            p.minDate = Date()
        }
        start.dateValue = nextHour
        end.dateValue = nextHour.addingTimeInterval(3600)
        end.isEnabled = false
        start.target = self
        start.action = #selector(startChanged)
        hasEnd.target = self
        hasEnd.action = #selector(toggleEnd)

        let startLabel = caption("STARTS")
        stack.addArrangedSubview(startLabel)
        stack.setCustomSpacing(6, after: startLabel)
        stack.addArrangedSubview(start)
        let endRow = NSStackView(views: [hasEnd, end])
        endRow.spacing = 12
        stack.addArrangedSubview(endRow)
        stack.setCustomSpacing(16, after: endRow)

        location = field("Location (optional)")
        addWide(location)
        desc = field("Description (optional)")
        desc.usesSingleLineMode = false
        desc.lineBreakMode = .byWordWrapping
        desc.cell?.wraps = true
        desc.cell?.isScrollable = false
        addWide(desc)
        desc.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        stack.setCustomSpacing(14, after: desc)
        let (row, s) = switchRow("Allow guests to bring someone", on: false)
        guests = s
        addWide(row)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(name)
    }

    @objc private func toggleEnd() {
        end.isEnabled = hasEnd.state == .on
        if end.isEnabled, end.dateValue <= start.dateValue { end.dateValue = start.dateValue.addingTimeInterval(3600) }
    }

    @objc private func startChanged() {
        if end.dateValue <= start.dateValue { end.dateValue = start.dateValue.addingTimeInterval(3600) }
    }

    func controlTextDidChange(_ obj: Notification) { validate() }

    override func validate() {
        primary.isEnabled = !(name?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    override func confirm() {
        validate()
        guard primary.isEnabled else { NSSound.beep(); return }
        let e = hasEnd.state == .on && end.dateValue > start.dateValue ? end.dateValue : nil
        onSend?(Draft(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), start: start.dateValue, end: e,
                      location: location.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                      desc: desc.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                      allowGuests: guests.state == .on))
        dismiss(nil)
    }
}

// MARK: - Contacts

/// Share contacts: search, tick one or more, send.
final class ContactPickerViewController: FormSheetViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSend: (([Store.Person]) -> Void)?
    private let store: Store
    private let exclude: String?
    private let search = NSSearchField()
    private let table = NSTableView()
    private var people: [Store.Person] = []
    private var picked: [String: Store.Person] = [:]

    init(store: Store, exclude: String?) {
        self.store = store
        self.exclude = exclude
        super.init(title: "Share Contacts", primary: "Send", width: 380)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        search.placeholderString = "Search"
        search.controlSize = .large
        search.target = self
        search.action = #selector(refill)
        search.sendsSearchStringImmediately = true
        addWide(search)

        let col = NSTableColumn(identifier: .init("p"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 44
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(toggleRow)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addWide(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 320).isActive = true
        refill()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    @objc private func refill() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        people = store.people(matching: q, limit: 80).filter {
            !$0.isGroup && $0.jid.hasSuffix("@s.whatsapp.net") && $0.jid != exclude && $0.jid != Core.shared.me
        }
        table.reloadData()
    }

    @objc private func toggleRow() {
        let row = table.clickedRow
        guard row >= 0, row < people.count else { return }
        let p = people[row]
        if picked[p.jid] != nil { picked[p.jid] = nil } else { picked[p.jid] = p }
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
        validate()
    }

    override func validate() {
        primary.isEnabled = !picked.isEmpty
        primary.title = picked.count > 1 ? "Send \(picked.count)" : "Send"
    }

    override func confirm() {
        guard !picked.isEmpty else { NSSound.beep(); return }
        onSend?(Array(picked.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        dismiss(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { people.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = people[row]
        let cell = PersonPickCell()
        cell.configure(p, avatar: store.avatar(p.jid), checked: picked[p.jid] != nil)
        return cell
    }
}

/// One row in the contact picker: avatar, name, number, and a check when picked.
private final class PersonPickCell: NSView {
    private let avatar = AvatarView()
    private let name = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let check = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        sub.font = .systemFont(ofSize: 11.5)
        sub.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for v in [avatar, text, check] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -8),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ p: Store.Person, avatar path: String, checked: Bool) {
        avatar.configure(jid: p.jid, name: p.name, isGroup: false, path: path, px: 64)
        name.stringValue = p.name
        sub.stringValue = p.subtitle
        let symbol = checked ? "checkmark.circle.fill" : "circle"
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            .applying(.init(paletteColors: [checked ? Theme.accent : NSColor.tertiaryLabelColor]))
        check.image = NSImage(systemSymbolName: symbol, accessibilityDescription: checked ? "Selected" : nil)?.withSymbolConfiguration(cfg)
    }
}

// MARK: - Votes and responses

/// Who voted for what in a poll, or who's coming to an event (with the event's
/// details, and Cancel Event for its host).
final class VotesView: NSView {
    var onCancelEvent: (() -> Void)? { didSet { cancelButton?.isHidden = onCancelEvent == nil } }
    private var cancelButton: NSButton?

    init(message m: Message) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 10))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 300),
        ])
        func label(_ s: String, _ font: NSFont, _ color: NSColor = .labelColor, lines: Int = 0) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = font
            l.textColor = color
            l.maximumNumberOfLines = lines
            l.preferredMaxLayoutWidth = 268
            return l
        }
        func section(_ title: String, _ count: Int, _ people: [Vote]) {
            let head = label(count == 0 ? title : "\(title) · \(count)", .systemFont(ofSize: 12, weight: .semibold), .secondaryLabelColor)
            stack.addArrangedSubview(head)
            stack.setCustomSpacing(6, after: head)
            if people.isEmpty {
                let none = label("No one yet", .systemFont(ofSize: 13), .tertiaryLabelColor)
                stack.addArrangedSubview(none)
                stack.setCustomSpacing(14, after: none)
                return
            }
            for (i, v) in people.enumerated() {
                let who = v.isMine ? "You" : v.name
                let guests = v.guests > 0 ? " +\(v.guests)" : ""
                let row = label(who + guests, .systemFont(ofSize: 13))
                stack.addArrangedSubview(row)
                if i == people.count - 1 { stack.setCustomSpacing(14, after: row) }
            }
        }
        let mineFirst: (Vote, Vote) -> Bool = { a, b in a.isMine != b.isMine ? a.isMine : a.ts < b.ts }

        if let poll = m.poll {
            let q = label(m.pollQuestion, .systemFont(ofSize: 15, weight: .semibold))
            stack.addArrangedSubview(q)
            stack.setCustomSpacing(14, after: q)
            let voters = m.votes.filter { !$0.options.isEmpty }
            // Most-voted first, like WhatsApp's details.
            let ranked = poll.options.enumerated().sorted { a, b in
                let ca = voters.filter { $0.options.contains(a.element) }.count
                let cb = voters.filter { $0.options.contains(b.element) }.count
                return ca != cb ? ca > cb : a.offset < b.offset
            }.map(\.element)
            for o in ranked {
                let who = voters.filter { $0.options.contains(o) }.sorted(by: mineFirst)
                section(o, who.count, who)
            }
        } else if let e = m.event {
            let name = label(m.text, .systemFont(ofSize: 15, weight: .semibold))
            stack.addArrangedSubview(name)
            let when = label(RichCard.when(e), .systemFont(ofSize: 12.5), .secondaryLabelColor)
            stack.addArrangedSubview(when)
            if let loc = e.loc, !loc.isEmpty { stack.addArrangedSubview(label("📍 " + loc, .systemFont(ofSize: 13))) }
            if let d = e.desc, !d.isEmpty { stack.addArrangedSubview(label(d, .systemFont(ofSize: 13), .labelColor)) }
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
            let going = m.votes.filter { $0.response == "going" }.sorted(by: mineFirst)
            let maybe = m.votes.filter { $0.response == "maybe" }.sorted(by: mineFirst)
            let no = m.votes.filter { $0.response == "not_going" }.sorted(by: mineFirst)
            section("Going", going.reduce(0) { $0 + 1 + $1.guests }, going)
            section("Maybe", maybe.count, maybe)
            section("Not going", no.count, no)
            if m.fromMe, !e.isCanceled {
                let b = NSButton(title: "Cancel Event", target: self, action: #selector(cancelEvent))
                b.contentTintColor = .systemRed
                b.bezelStyle = .push
                b.isHidden = true
                cancelButton = b
                stack.addArrangedSubview(b)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func cancelEvent() {
        window?.performClose(nil)
        onCancelEvent?()
    }
}
