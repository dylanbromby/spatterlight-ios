import UIKit

/// A text field that reports each key as it is typed, for games that wait for a keypress.
final class KeyCaptureTextField: UITextField {
    var onDeleteBackward: (() -> Void)?
    /// The colour of the placeholder text, so it can follow the reading theme.
    var placeholderColor: UIColor? { didSet { setNeedsDisplay() } }

    override func drawPlaceholder(in rect: CGRect) {
        guard let color = placeholderColor, let placeholder = placeholder else { return super.drawPlaceholder(in: rect) }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? UIFont.preferredFont(forTextStyle: .body), .foregroundColor: color]
        let size = (placeholder as NSString).size(withAttributes: attributes)
        (placeholder as NSString).draw(in: CGRect(x: rect.minX, y: rect.minY + (rect.height - size.height) / 2, width: rect.width, height: size.height), withAttributes: attributes)
    }

    override func deleteBackward() {
        if text?.isEmpty ?? true { onDeleteBackward?() }
        super.deleteBackward()
    }
}

/// The bar at the bottom of the story where you type, with the keys that are
/// awkward on a phone keyboard (space, return, arrows) one tap away.
final class InputBar: UIView, UITextFieldDelegate {
    enum Mode: Equatable { case idle, line, key, finished }

    private(set) var mode: Mode = .idle
    let field = KeyCaptureTextField()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let separator = UIView()
    private let sendButton = UIButton(type: .system)
    private let upButton = UIButton(type: .system)
    private let downButton = UIButton(type: .system)
    private let keyRow = UIStackView()
    private let fieldRow = UIStackView()
    private let contentStack = UIStackView()
    private var showKeyRow = true
    private let idleLabel = UILabel()

    var onSubmitLine: ((String) -> Void)?
    var onKey: ((UInt32) -> Void)?
    var onHistory: ((Bool) -> String?)?
    var onFocusChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        addSubview(blur)
        blur.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        field.placeholder = "What do you do?"
        field.borderStyle = .none
        field.backgroundColor = UIColor.secondarySystemFill
        field.layer.cornerRadius = 10
        field.layer.cornerCurve = .continuous
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .send
        field.enablesReturnKeyAutomatically = false
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.font = UIFont.preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        field.leftViewMode = .always
        field.accessibilityLabel = "Command"
        field.accessibilityHint = "Type what you want to do, then send it."
        field.onDeleteBackward = { [weak self] in
            guard let self = self, self.mode == .key else { return }
            self.onKey?(UInt32(keycode_Delete))
        }
        field.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        func configure(_ button: UIButton, symbol: String, label: String) {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: symbol)
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
            button.configuration = config
            button.accessibilityLabel = label
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        configure(upButton, symbol: "chevron.up", label: "Previous command")
        configure(downButton, symbol: "chevron.down", label: "Next command")
        var sendConfig = UIButton.Configuration.filled()
        sendConfig.image = UIImage(systemName: "arrow.up")
        sendConfig.cornerStyle = .capsule
        sendConfig.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        sendButton.configuration = sendConfig
        sendButton.accessibilityLabel = "Send"
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        upButton.addTarget(self, action: #selector(historyUp), for: .touchUpInside)
        downButton.addTarget(self, action: #selector(historyDown), for: .touchUpInside)

        fieldRow.axis = .horizontal
        fieldRow.alignment = .center
        fieldRow.spacing = 4
        [upButton, downButton, field, sendButton].forEach { fieldRow.addArrangedSubview($0) }

        keyRow.axis = .horizontal
        keyRow.alignment = .fill
        keyRow.distribution = .fillEqually
        keyRow.spacing = 6
        let keys: [(String, String, UInt32)] = [
            ("Space", "space", 0x20), ("Return", "return", UInt32(keycode_Return)),
            ("←", "Left", UInt32(keycode_Left)), ("↑", "Up", UInt32(keycode_Up)),
            ("↓", "Down", UInt32(keycode_Down)), ("→", "Right", UInt32(keycode_Right)),
            ("Esc", "Escape", UInt32(keycode_Escape)),
        ]
        for (title, label, code) in keys {
            var config = UIButton.Configuration.tinted()
            config.title = title
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.preferredFont(forTextStyle: .callout)
                return outgoing
            }
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.sendKey(code) })
            button.accessibilityLabel = label
            keyRow.addArrangedSubview(button)
        }

        idleLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        idleLabel.textColor = .secondaryLabel
        idleLabel.textAlignment = .center
        idleLabel.numberOfLines = 0
        idleLabel.adjustsFontForContentSizeCategory = true

        contentStack.axis = .vertical
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(idleLabel)
        contentStack.addArrangedSubview(fieldRow)
        contentStack.addArrangedSubview(keyRow)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            contentStack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setMode(.idle, showKeyRow: true)
    }

    // MARK: Theme

    /// Make the bar part of the page: the reading theme's colours instead of the system's.
    func apply(colors: ReaderTheme.Colors) {
        blur.isHidden = true
        backgroundColor = colors.background
        separator.backgroundColor = colors.text.withAlphaComponent(0.18)
        field.backgroundColor = colors.gridBackground
        field.textColor = colors.text
        field.placeholderColor = colors.text.withAlphaComponent(0.5)
        field.keyboardAppearance = colors.isDark ? .dark : .light
        idleLabel.textColor = colors.text.withAlphaComponent(0.7)
        overrideUserInterfaceStyle = colors.isDark ? .dark : .light
        // Buttons, the caret and the send arrow take the accent colour.
        tintColor = colors.input
    }

    // MARK: Modes

    func setMode(_ newMode: Mode, showKeyRow: Bool, initialText: String = "", message: String? = nil) {
        let changed = newMode != mode
        mode = newMode
        self.showKeyRow = showKeyRow
        switch newMode {
        case .line:
            idleLabel.isHidden = true
            fieldRow.isHidden = false
            keyRow.isHidden = true
            upButton.isHidden = false
            downButton.isHidden = false
            sendButton.isHidden = false
            field.placeholder = "What do you do?"
            field.returnKeyType = .send
            field.clearButtonMode = .whileEditing
            if changed || !initialText.isEmpty { field.text = initialText }
            field.isEnabled = true
        case .key:
            idleLabel.isHidden = true
            fieldRow.isHidden = false
            keyRow.isHidden = !showKeyRow
            upButton.isHidden = true
            downButton.isHidden = true
            sendButton.isHidden = true
            field.placeholder = "Press any key"
            field.returnKeyType = .default
            field.clearButtonMode = .never
            field.text = ""
            field.isEnabled = true
        case .idle:
            // The story is busy. The field stays, so the keyboard does not
            // flicker and the next command can be typed ahead.
            idleLabel.isHidden = true
            fieldRow.isHidden = false
            keyRow.isHidden = true
            upButton.isHidden = false
            downButton.isHidden = false
            sendButton.isHidden = false
            field.placeholder = message ?? "…"
            field.returnKeyType = .send
            field.clearButtonMode = .whileEditing
            field.isEnabled = true
        case .finished:
            idleLabel.isHidden = false
            idleLabel.text = message ?? "The story has ended."
            fieldRow.isHidden = true
            keyRow.isHidden = true
        }
        invalidateIntrinsicContentSize()
        sendButton.isEnabled = true
    }

    var text: String { field.text ?? "" }

    func focus() { field.becomeFirstResponder() }

    // MARK: Actions

    @objc private func editingChanged() {}

    @objc private func sendTapped() { submit() }

    @objc private func historyUp() { if let text = onHistory?(true) { field.text = text } }
    @objc private func historyDown() { if let text = onHistory?(false) { field.text = text } }

    func submit() {
        guard mode == .line || mode == .idle else { return }
        let text = field.text ?? ""
        field.text = ""
        onSubmitLine?(text)
    }

    private func sendKey(_ code: UInt32) {
        guard mode == .key else { return }
        onKey?(code)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        switch mode {
        case .line, .idle: submit()
        case .key: onKey?(UInt32(keycode_Return))
        default: break
        }
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard mode == .key else { return true }
        for scalar in string.unicodeScalars { onKey?(scalar.value) }
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { onFocusChange?(true) }
    func textFieldDidEndEditing(_ textField: UITextField) { onFocusChange?(false) }
}
