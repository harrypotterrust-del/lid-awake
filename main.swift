import AppKit

// MARK: - Sleep control (pmset)

enum SleepService {
    /// true, если системный сон отключён (pmset -a disablesleep 1).
    static func isDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.first == "SleepDisabled" && parts.last == "1"
        }
    }

    /// Меняет режим: сначала через sudo без пароля (если правило установлено),
    /// иначе через стандартный системный запрос пароля администратора.
    static func setDisabled(_ disabled: Bool) -> Bool {
        let value = disabled ? "1" : "0"
        if run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]) { return true }
        return runAsAdmin("/usr/bin/pmset -a disablesleep \(value)")
    }

    // MARK: Passwordless mode (sudoers rule)

    static let sudoersFile = "/etc/sudoers.d/lidawake"

    static func isPasswordless() -> Bool {
        FileManager.default.fileExists(atPath: sudoersFile)
    }

    /// Разрешает без пароля ровно две команды: pmset -a disablesleep 0 и 1.
    static func installPasswordless() -> Bool {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: "
            + "/usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lidawake.sudoers")
        guard (try? rule.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        // visudo проверяет синтаксис, чтобы битое правило не сломало sudo.
        return runAsAdmin("/usr/sbin/visudo -cf '\(tmp.path)' && "
            + "/usr/bin/install -m 0440 -o root -g wheel '\(tmp.path)' \(sudoersFile)")
    }

    static func removePasswordless() -> Bool {
        runAsAdmin("/bin/rm -f \(sudoersFile)")
    }

    // MARK: Helpers

    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func runAsAdmin(_ cmd: String) -> Bool {
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err == nil
    }

    /// Гасит экран сразу (root не нужен).
    static func displayOffNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}

// MARK: - Menu bar controller

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var awake = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Option-клик / правый клик → меню, обычный клик → переключить.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(buttonClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.menu = nil

        refresh()
        // Подхватываем изменения, сделанные из терминала.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @objc private func refresh() {
        awake = SleepService.isDisabled()
        guard let button = statusItem.button else { return }
        let symbol = awake ? "cup.and.saucer.fill" : "moon.zzz"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.toolTip = awake
            ? "Мак НЕ засыпает (можно закрыть крышку)\nКлик — выключить · правый клик — меню"
            : "Обычный режим сна\nКлик — не засыпать с закрытой крышкой · правый клик — меню"
    }

    // MARK: Click handling

    @objc private func buttonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            let menu = NSMenu()
            menu.delegate = self
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggle()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refresh()

        let status = NSMenuItem(title: awake ? "☕ Не засыпает с закрытой крышкой" : "💤 Обычный сон",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: awake ? "Вернуть обычный сон" : "Не засыпать (крышка закрыта)",
                                action: #selector(toggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let off = NSMenuItem(title: "Погасить экран", action: #selector(displayOff), keyEquivalent: "")
        off.target = self
        menu.addItem(off)

        menu.addItem(.separator())
        let pw = NSMenuItem(title: "Не спрашивать пароль", action: #selector(togglePasswordless),
                            keyEquivalent: "")
        pw.target = self
        pw.state = SleepService.isPasswordless() ? .on : .off
        menu.addItem(pw)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Actions

    @objc private func toggle() {
        _ = SleepService.setDisabled(!awake)   // отмена пароля → просто ничего не меняется
        refresh()
        flash(awake ? " Не спит" : " Сон вкл")
    }

    @objc private func displayOff() { SleepService.displayOffNow() }

    @objc private func togglePasswordless() {
        let ok = SleepService.isPasswordless()
            ? SleepService.removePasswordless()
            : SleepService.installPasswordless()
        if ok { flash(SleepService.isPasswordless() ? " Без пароля" : " С паролем") }
    }

    private func flash(_ text: String) {
        guard let button = statusItem.button else { return }
        button.title = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { button.title = "" }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon, menu bar only
app.run()
