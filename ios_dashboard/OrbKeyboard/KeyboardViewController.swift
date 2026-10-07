import OrbLocalKit
import UIKit

/// Orb keyboard. iOS only runs a custom keyboard while it is the active,
/// visible keyboard, and never in secure or phone-pad fields. Inside those
/// limits it drains Orb's App Group command queue and applies each command to
/// the focused field through `UITextDocumentProxy`. It never reads secure text,
/// never stores what it reads, and opens no other apps (App Review 4.4.1).
final class KeyboardViewController: UIInputViewController {
    private var queue: KeyboardCommandQueue?
    private var timer: Timer?
    private let status = UILabel()
    private let nextKeyboard = UIButton(type: .system)
    private var hasFullAccessCached = false

    override func viewDidLoad() {
        super.viewDidLoad()
        if let root = OrbAppGroup.keyboard { queue = KeyboardCommandQueue(root: root) }
        hasFullAccessCached = hasFullAccess
        buildUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        beacon(visible: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop.
            MainActor.assumeIsolated {
                self?.drain()
                self?.beacon(visible: true)
            }
        }
        drain()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate(); timer = nil
        beacon(visible: false)
    }

    private func buildUI() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        nextKeyboard.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboard.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        nextKeyboard.isHidden = !needsInputModeSwitchKey
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.numberOfLines = 2
        status.text = hasFullAccessCached ? "Orb agent keyboard · ready" : "Orb keyboard · enable Allow Full Access so Orb can send text"
        let ret = UIButton(type: .system)
        ret.setTitle("return", for: .normal)
        ret.addAction(UIAction { [weak self] _ in self?.textDocumentProxy.insertText("\n") }, for: .touchUpInside)
        let del = UIButton(type: .system)
        del.setImage(UIImage(systemName: "delete.left"), for: .normal)
        del.addAction(UIAction { [weak self] _ in self?.textDocumentProxy.deleteBackward() }, for: .touchUpInside)
        [nextKeyboard, status, del, ret].forEach(stack.addArrangedSubview)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            view.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    private func beacon(visible: Bool) {
        queue?.setPresence(KeyboardPresence(visible: visible, fullAccess: hasFullAccessCached))
    }

    private func drain() {
        guard let queue else { return }
        let commands = queue.drain()
        guard !commands.isEmpty else { return }
        let proxy = textDocumentProxy
        for command in commands {
            var ok = true
            var reason: String?
            switch command.kind {
            case .insert:
                if let text = command.text, !text.isEmpty { proxy.insertText(text) } else { ok = false; reason = "empty text" }
            case .delete:
                for _ in 0..<min(max(1, command.count ?? 1), 512) { proxy.deleteBackward() }
            case .return:
                proxy.insertText("\n")
            case .context:
                break
            }
            queue.complete(KeyboardResult(
                id: command.id, ok: ok, reason: reason,
                before: proxy.documentContextBeforeInput.map { String($0.suffix(2000)) },
                after: proxy.documentContextAfterInput.map { String($0.prefix(2000)) },
                selected: proxy.selectedText, keyboardType: proxy.keyboardType?.rawValue,
                returnKeyType: proxy.returnKeyType?.rawValue, hostBundleID: nil))
        }
        status.text = "Orb typed \(commands.count) command\(commands.count == 1 ? "" : "s")"
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(KeyboardCommandQueue.resultNotification as CFString), nil, nil, true)
    }

    override func textDidChange(_ textInput: UITextInput?) { drain() }
}
