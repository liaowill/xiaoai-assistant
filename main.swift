import AppKit
import Foundation

// MARK: - 路径

// 运行数据统一放在当前用户的 Application Support，不写死任何人的目录
let kProject = NSHomeDirectory() + "/Library/Application Support/XiaoAIAssistant"
let kStartScript = kProject + "/start.sh"
let kLogFile = kProject + "/service.log"
let kConfigFile = kProject + "/xiao_config.yaml"
let kConvoFile = kProject + "/conversations.jsonl"
let kSetupScript = kProject + "/重新设置.command"
let kAppPath = "/Applications/小爱助手.app"
let kOldPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.xiaoai-assistant.old.plist"
let kPlistLabel = "com.xiaoai-assistant.mac"
let kPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/" + kPlistLabel + ".plist"

// MARK: - 状态

enum RunState: String {
    case starting = "正在连接…"
    case ready = "已连接，可以用了"
    case needVerify = "需要短信验证"
    case failed = "连接出错"
    case stopped = "已停止"

    var tint: NSColor {
        switch self {
        case .ready: return .systemGreen
        case .starting, .needVerify: return .systemOrange
        case .failed: return .systemRed
        case .stopped: return .secondaryLabelColor
        }
    }

    var hint: String {
        switch self {
        case .ready:
            return "对音箱说：「小爱同学，请问……」\n关键词「请问 / 帮我 / 回答」要放在开头。"
        case .starting: return "正在登录小米云并启动桥接服务，稍等几秒。"
        case .needVerify: return "屏幕上会弹出小米安全验证框，填入短信验证码即可。"
        case .failed: return "点「重新启动」再试；仍不行就查看运行日志。"
        case .stopped: return "点「重新启动」即可恢复。"
        }
    }
}

func nowString() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

func todayString() -> String {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f.string(from: Date())
}

func sanitize(_ s: String) -> String {
    s.replacingOccurrences(of: "(ak_|sk-)[A-Za-z0-9_-]+",
                           with: "[凭据已隐藏]",
                           options: .regularExpression)
}

@discardableResult
func runSync(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.launchPath = path
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func keychainGet(_ service: String) -> String {
    let p = Process()
    p.launchPath = "/usr/bin/security"
    p.arguments = ["find-generic-password", "-a", "xiaoai", "-s", service, "-w"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

@discardableResult
func keychainSet(_ service: String, _ value: String) -> Bool {
    let p = Process()
    p.launchPath = "/usr/bin/security"
    p.arguments = ["add-generic-password", "-a", "xiaoai", "-s", service, "-w", value, "-U"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func notify(_ text: String) {
    let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
    DispatchQueue.global().async {
        _ = runSync("/usr/bin/osascript", ["-e", "display notification \"\(escaped)\" with title \"小爱助手\""])
    }
}

func replaceConfigLine(_ text: String, _ pattern: String, _ replacement: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
    let safe = NSRegularExpression.escapedTemplate(for: replacement)
    return re.stringByReplacingMatches(in: text,
                                       range: NSRange(text.startIndex..., in: text),
                                       withTemplate: safe)
}

// MARK: - 对话记录

struct Conversation: Codable {
    var time: String
    var question: String
    var xiaoai: String
    var model: String
    var answer: String
}

struct ConversationDraft {
    var time = ""
    var question = ""
    var xiaoai = ""
    var model = ""
    var answer = ""
}

func parseConversations(from text: String) -> [Conversation] {
    let dec = JSONDecoder()
    return text.split(separator: "\n").compactMap {
        try? dec.decode(Conversation.self, from: Data(String($0).utf8))
    }
}

/// 从 xiaogpt 的日志文本里提取一问一答（App 启动时也用它回填历史记录）
func extractConversations(from text: String) -> [Conversation] {
    var result: [Conversation] = []
    var d = ConversationDraft()
    for raw in text.split(separator: "\n") {
        let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("问题：") {
            d = ConversationDraft(time: "", question: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
        } else if line.hasPrefix("以下是小爱的回答：") {
            d.xiaoai = line.replacingOccurrences(of: "以下是小爱的回答：", with: "")
                .trimmingCharacters(in: .whitespaces)
        } else if let r = line.range(of: " 的回答：") {
            d.model = String(line[..<r.lowerBound]).replacingOccurrences(of: "以下是 ", with: "")
            d.answer = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if line == "回答完毕" {
            if !d.question.isEmpty {
                result.append(Conversation(time: d.time, question: d.question,
                                           xiaoai: d.xiaoai, model: d.model, answer: d.answer))
            }
            d = ConversationDraft()
        } else if !d.answer.isEmpty {
            d.answer += " " + line
        }
    }
    return result
}

// MARK: - 应用主体

final class AppController: NSObject, NSApplicationDelegate,
                           NSTableViewDataSource, NSTableViewDelegate {

    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var stateLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var modelLabel: NSTextField!
    private var badgeDot: NSImageView!
    private var badgeText: NSTextField!
    private var autoSwitch: NSSwitch!
    private var mainTableView: NSTableView?      // 首页最近对话
    private var mainEmptyHint: NSTextField?
    private var mainDeleteButton: NSButton?
    private var conversationDeleteButton: NSButton?

    private var conversationWindow: NSWindow?
    private var conversationTable: NSTableView?
    private var conversationDetail: NSTextView?
    private var conversationCount: NSTextField?

    private var logWindow: NSWindow?             // 运行日志，按需打开
    private var logTextView: NSTextView?

    private var settingsWindow: NSWindow?
    private var fModel: NSTextField!
    private var fBase: NSTextField!
    private var fKey: NSSecureTextField!
    private var fKeyPlain: NSTextField!          // 显示密钥时用的普通输入框
    private var fKeyRevealButton: NSButton!
    private var keyRevealed = false
    private var fPreset: NSPopUpButton!
    private var fTestResult: NSTextField!

    private var process: Process?
    private var pipe: Pipe?
    private var logLines: [String] = []
    private var pendingLine = ""
    private var conversations: [Conversation] = []
    private var draft = ConversationDraft()

    private var state: RunState = .stopped { didSet { refreshUI() } }

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureFiles()
        loadConversations()
        buildMenuBar()
        buildMainWindow()

        _ = runSync("/bin/launchctl", ["unload", kOldPlist])

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshUI()
        refreshModelLabel()
        reloadConversationWindow()
        startService()

        // 键盘 Delete / Forward Delete 删除选中记录；输入框在前台时不生效
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard event.keyCode == 51 || event.keyCode == 117 else { return event }
            guard let table = self.activeConversationTable(),
                  !table.selectedRowIndexes.isEmpty else { return event }
            self.deleteSelectedConversations()
            return nil
        }

        // 预览开关：只用于打开面板做视觉核对，不含任何改数据的动作
        var panel: String? = nil
        if let i = CommandLine.arguments.firstIndex(of: "--panel"),
           i + 1 < CommandLine.arguments.count {
            panel = CommandLine.arguments[i + 1]
        } else {
            panel = UserDefaults.standard.string(forKey: "DebugPanel")
        }
        if let which = panel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if which == "conversations" { self?.openConversations() }
                else if which == "settings" { self?.openSettings() }
                else if which == "log" { self?.openLogWindow() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { stopService() }

    // MARK: 文件

    private func ensureFiles() {
        if !FileManager.default.fileExists(atPath: kLogFile) {
            FileManager.default.createFile(atPath: kLogFile, contents: Data())
        }
        if !FileManager.default.fileExists(atPath: kConvoFile) {
            // 首次启动：把 service.log 里的历史问答回填进来
            let old = (try? String(contentsOfFile: kLogFile, encoding: .utf8)) ?? ""
            let found = extractConversations(from: old)
            let enc = JSONEncoder()
            var text = ""
            for var c in found {
                if c.time.isEmpty { c.time = "历史" }
                if let d = try? enc.encode(c), let s = String(data: d, encoding: .utf8) {
                    text += s + "\n"
                }
            }
            try? text.write(toFile: kConvoFile, atomically: true, encoding: .utf8)
        }
    }

    private func loadConversations() {
        let text = (try? String(contentsOfFile: kConvoFile, encoding: .utf8)) ?? ""
        conversations = parseConversations(from: text)
    }

    private func appendConversation(_ c: Conversation) {
        let enc = JSONEncoder()
        guard let d = try? enc.encode(c), let s = String(data: d, encoding: .utf8) else { return }
        let line = s + "\n"
        if let h = FileHandle(forWritingAtPath: kConvoFile) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            h.closeFile()
        } else {
            try? line.write(toFile: kConvoFile, atomically: true, encoding: .utf8)
        }
        conversations.append(c)
        if conversations.count > 500 { conversations = Array(conversations.suffix(500)) }
        reloadConversationWindow()
    }

    // MARK: 日志与问答解析

    private func addLogLine(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { logLines.append("[" + nowString() + "] " + s) }
        parseLogLine(s)
    }

    private func appendLog(_ raw: String) {
        let text = sanitize(raw)
        let combined = pendingLine + text
        let parts = combined.split(separator: "\n", omittingEmptySubsequences: false)
        if !combined.hasSuffix("\n"), !parts.isEmpty {
            pendingLine = String(parts.last!)
            for part in parts.dropLast() { addLogLine(String(part)) }
        } else {
            pendingLine = ""
            for part in parts { addLogLine(String(part)) }
        }
        if logLines.count > 200 { logLines = Array(logLines.suffix(200)) }
        // 日志不再常驻首页；只有日志窗口开着时才实时刷新界面
        if logWindow?.isVisible == true { refreshLogWindow() }

        if let h = FileHandle(forWritingAtPath: kLogFile) {
            h.seekToEndOfFile()
            if let d = text.data(using: .utf8) { h.write(d) }
            h.closeFile()
        }
    }

    private func parseLogLine(_ line: String) {
        if line.hasPrefix("问题：") {
            draft = ConversationDraft(time: todayString(),
                                      question: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
        } else if line.hasPrefix("以下是小爱的回答：") {
            draft.xiaoai = line.replacingOccurrences(of: "以下是小爱的回答：", with: "")
                .trimmingCharacters(in: .whitespaces)
        } else if let r = line.range(of: " 的回答：") {
            draft.model = String(line[..<r.lowerBound]).replacingOccurrences(of: "以下是 ", with: "")
            draft.answer = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if line == "回答完毕" {
            if !draft.question.isEmpty {
                appendConversation(Conversation(time: draft.time, question: draft.question,
                                                xiaoai: draft.xiaoai, model: draft.model,
                                                answer: draft.answer))
            }
            draft = ConversationDraft()
        } else if !draft.answer.isEmpty {
            draft.answer += " " + line
        }
    }

    private func handleOutput(_ text: String) {
        appendLog(text)
        if text.contains("Running xiaogpt now") {
            state = .ready
            refreshModelLabel()
            notify("小爱已连上大模型，可以说「小爱同学，请问……」")
        } else if text.contains("Login failed") || text.contains("验证没完成")
                    || text.contains("Traceback") || text.contains("小米账号或密码没存好") {
            state = .failed
        } else if text.contains("安全验证") || text.contains("验证码") {
            state = .needVerify
        }
    }

    // MARK: 服务

    private func startService() {
        stopService()
        _ = runSync("/usr/bin/pkill", ["-f", "xiaogpt --config xiao_config.yaml"])
        state = .starting
        appendLog("=== \(todayString()) 小爱助手启动连接 ===\n")

        let p = Process()
        p.launchPath = "/bin/bash"
        p.arguments = [kStartScript]
        p.currentDirectoryURL = URL(fileURLWithPath: kProject)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
        env["HOME"] = NSHomeDirectory()
        env["LANG"] = "zh_CN.UTF-8"
        p.environment = env

        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.handleOutput(s) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.state != .stopped { self.state = .failed }
                self.process = nil
            }
        }
        do {
            try p.run()
            process = p
            pipe = outPipe
        } catch {
            appendLog("启动失败：\(error.localizedDescription)\n")
            state = .failed
        }
    }

    private func stopService() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        pipe = nil
    }

    // MARK: 主窗口（macOS 设计语言）

    private func refreshUI() {
        stateLabel.stringValue = state.rawValue
        stateLabel.textColor = state.tint
        hintLabel.stringValue = state.hint
        badgeDot.contentTintColor = state.tint
        badgeText.stringValue = state.rawValue
        statusItem.button?.toolTip = "小爱助手 · " + state.rawValue
        if let item = statusItem.menu?.item(withTag: 100) { item.title = state.rawValue }
        autoSwitch.state = autoLaunchEnabled() ? .on : .off
    }

    private func refreshModelLabel() {
        let cfg = currentConfig()
        modelLabel.stringValue = "第一代小爱音箱 · \(cfg.model) · 本机运行"
    }

    private func label(_ frame: NSRect, _ text: String, _ size: CGFloat,
                       _ weight: NSFont.Weight, _ color: NSColor) -> NSTextField {
        let l = NSTextField(frame: frame)
        l.stringValue = text
        l.isBezeled = false
        l.drawsBackground = false
        l.isEditable = false
        l.isSelectable = false
        l.lineBreakMode = .byWordWrapping
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func iconButton(_ title: String, _ symbol: String,
                            _ frame: NSRect, _ action: Selector) -> NSButton {
        let b = NSButton(frame: frame)
        b.title = title
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        img?.isTemplate = true
        b.image = img
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.target = self
        b.action = action
        return b
    }

    /// 纯代码建的 AppKit 应用没有 MainMenu.nib。不补这个主菜单，
    /// Cmd+C / Cmd+V 就没有对应的菜单项，所有输入框都只能一个字一个字敲。
    /// 菜单项 target 留空，快捷键会沿响应链自动交给当前正在编辑的输入框。
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.title = "小爱助手"
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于小爱助手",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏小爱助手",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出小爱助手",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "最小化", action: Selector(("performMiniaturize:")), keyEquivalent: "m")
        win.addItem(withTitle: "关闭", action: Selector(("performClose:")), keyEquivalent: "w")
        windowItem.submenu = win
        main.addItem(windowItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    private func buildMenuBar() {
        buildMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            let img = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: "小爱助手")
            img?.isTemplate = true
            btn.image = img
            btn.toolTip = "小爱助手"
        }
        let menu = NSMenu()
        let head = NSMenuItem(title: "状态", action: nil, keyEquivalent: "")
        head.tag = 100
        menu.addItem(head)
        menu.addItem(.separator())
        menu.addItem(item("显示主窗口", #selector(showWindow), ""))
        menu.addItem(item("对话记录", #selector(openConversations), "d"))
        menu.addItem(item("模型 API 设置", #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item("重新启动连接", #selector(restart), "r"))
        menu.addItem(item("停止连接", #selector(stop), "s"))
        menu.addItem(.separator())
        menu.addItem(item("运行日志", #selector(openLogWindow), ""))
        menu.addItem(item("重新设置账号", #selector(openSetup), ""))
        menu.addItem(.separator())
        menu.addItem(item("退出小爱助手", #selector(quit), "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func separator(_ y: CGFloat, _ width: CGFloat) -> NSBox {
        let b = NSBox(frame: NSRect(x: 24, y: y, width: width - 48, height: 1))
        b.boxType = .separator
        return b
    }

    private func buildMainWindow() {
        let w: CGFloat = 660, h: CGFloat = 580
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "小爱助手"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.isReleasedWhenClosed = false

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .followsWindowActiveState
        window.contentView = bg

        // 顶部：应用图标 / 标题 / 状态徽章
        let iconView = NSImageView(frame: NSRect(x: 28, y: 496, width: 56, height: 56))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        bg.addSubview(iconView)

        bg.addSubview(label(NSRect(x: 96, y: 524, width: 320, height: 28),
                            "小爱助手", 22, .semibold, .labelColor))
        modelLabel = label(NSRect(x: 96, y: 500, width: 360, height: 20),
                           "第一代小爱音箱 · 本机运行", 12, .regular, .secondaryLabelColor)
        bg.addSubview(modelLabel)

        let badge = NSBox(frame: NSRect(x: w - 208, y: 512, width: 180, height: 34))
        badge.boxType = .custom
        badge.cornerRadius = 17
        badge.borderWidth = 0
        badge.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.7)
        bg.addSubview(badge)
        badgeDot = NSImageView(frame: NSRect(x: w - 192, y: 525, width: 10, height: 10))
        let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot?.isTemplate = true
        badgeDot.image = dot
        badgeDot.contentTintColor = .systemGreen
        bg.addSubview(badgeDot)
        badgeText = label(NSRect(x: w - 174, y: 518, width: 140, height: 22),
                          "正在连接…", 12, .medium, .labelColor)
        bg.addSubview(badgeText)

        bg.addSubview(separator(484, w))

        // 状态卡片
        let card = NSBox(frame: NSRect(x: 24, y: 370, width: w - 48, height: 100))
        card.boxType = .custom
        card.cornerRadius = 12
        card.borderWidth = 0
        card.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55)
        bg.addSubview(card)

        stateLabel = label(NSRect(x: 44, y: 426, width: w - 88, height: 30),
                           "正在连接…", 20, .semibold, .systemOrange)
        bg.addSubview(stateLabel)
        hintLabel = label(NSRect(x: 44, y: 380, width: w - 88, height: 42),
                          "", 12.5, .regular, .secondaryLabelColor)
        bg.addSubview(hintLabel)

        // 操作行
        let btnY: CGFloat = 324, btnH: CGFloat = 32
        bg.addSubview(iconButton("重新启动", "arrow.clockwise",
                                 NSRect(x: 24, y: btnY, width: 116, height: btnH), #selector(restart)))
        bg.addSubview(iconButton("停止", "stop.fill",
                                 NSRect(x: 148, y: btnY, width: 92, height: btnH), #selector(stop)))
        bg.addSubview(iconButton("对话记录", "bubble.left.and.bubble.right",
                                 NSRect(x: 248, y: btnY, width: 122, height: btnH), #selector(openConversations)))
        bg.addSubview(iconButton("模型设置", "gearshape",
                                 NSRect(x: 378, y: btnY, width: 116, height: btnH), #selector(openSettings)))
        bg.addSubview(iconButton("查看日志", "doc.text",
                                 NSRect(x: 502, y: btnY, width: 134, height: btnH), #selector(openLogWindow)))

        // 首页主体：最近对话（日志收进「查看日志」按钮）
        bg.addSubview(label(NSRect(x: 24, y: 296, width: 200, height: 20),
                            "最近对话", 12, .semibold, .secondaryLabelColor))

        let delBtn = iconButton("删除", "trash",
                                NSRect(x: w - 240, y: 291, width: 100, height: 26),
                                #selector(deleteSelectedConversations))
        delBtn.isEnabled = false
        delBtn.toolTip = "删除选中的对话记录（也可按 Delete 键，支持多选）"
        bg.addSubview(delBtn)
        mainDeleteButton = delBtn

        let showAll = NSButton(frame: NSRect(x: w - 132, y: 292, width: 108, height: 24))
        showAll.title = "查看全部"
        showAll.bezelStyle = .recessed
        showAll.isBordered = false
        showAll.font = .systemFont(ofSize: 11.5)
        showAll.target = self
        showAll.action = #selector(openConversations)
        bg.addSubview(showAll)

        let tableScroll = NSScrollView(frame: NSRect(x: 24, y: 68, width: w - 48, height: 218))
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .noBorder
        tableScroll.drawsBackground = true
        tableScroll.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.55)
        tableScroll.wantsLayer = true
        tableScroll.layer?.cornerRadius = 8

        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: w - 48, height: 218))
        for (ident, title, width) in [
            ("time", "时间", 96), ("question", "你问", 190), ("answer", "大模型回答", 318)
        ] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ident))
            col.title = title
            col.width = CGFloat(width)
            table.addTableColumn(col)
        }
        table.headerView = NSTableHeaderView()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.doubleAction = #selector(openConversations)
        table.target = self
        tableScroll.documentView = table
        bg.addSubview(tableScroll)
        mainTableView = table

        mainEmptyHint = label(NSRect(x: 40, y: 160, width: w - 80, height: 24),
                              "还没有对话记录。对音箱说「小爱同学，请问……」", 12, .regular, .secondaryLabelColor)
        mainEmptyHint?.alignment = .center
        mainEmptyHint?.isHidden = true
        if let hint = mainEmptyHint { bg.addSubview(hint) }

        bg.addSubview(separator(56, w))
        autoSwitch = NSSwitch(frame: NSRect(x: 24, y: 20, width: 38, height: 22))
        autoSwitch.target = self
        autoSwitch.action = #selector(toggleAuto)
        bg.addSubview(autoSwitch)
        bg.addSubview(label(NSRect(x: 70, y: 21, width: 260, height: 20),
                            "开机自动打开小爱助手", 12, .regular, .labelColor))
        let ver = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "2.3"
        bg.addSubview(label(NSRect(x: w - 150, y: 21, width: 126, height: 20),
                            "版本 \(ver) · 本机运行", 11, .regular, .tertiaryLabelColor))
    }

    // MARK: 对话记录窗口

    private func buildConversationWindow() {
        let w: CGFloat = 760, h: CGFloat = 460
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "对话记录"
        win.titlebarAppearsTransparent = true
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 560, height: 340)

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .followsWindowActiveState
        win.contentView = bg

        let tableScroll = NSScrollView(frame: NSRect(x: 20, y: 62, width: 320, height: h - 122))
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: h - 122))
        let c1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        c1.title = "时间"
        c1.width = 92
        let c2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("question"))
        c2.title = "问题"
        c2.width = 210
        table.addTableColumn(c1)
        table.addTableColumn(c2)
        table.headerView = NSTableHeaderView()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        tableScroll.documentView = table
        bg.addSubview(tableScroll)

        let detailScroll = NSScrollView(frame: NSRect(x: 352, y: 62, width: w - 372, height: h - 122))
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        let detail = NSTextView(frame: NSRect(x: 0, y: 0, width: w - 372, height: h - 122))
        detail.isEditable = false
        detail.font = .systemFont(ofSize: 13)
        detail.textContainerInset = NSSize(width: 12, height: 12)
        detailScroll.documentView = detail
        bg.addSubview(detailScroll)

        let clear = NSButton(frame: NSRect(x: 20, y: 18, width: 96, height: 30))
        clear.title = "清空记录"
        clear.bezelStyle = .rounded
        clear.target = self
        clear.action = #selector(clearConversations)
        bg.addSubview(clear)

        let delSel = iconButton("删除选中", "trash",
                                NSRect(x: 124, y: 18, width: 112, height: 30),
                                #selector(deleteSelectedConversations))
        delSel.isEnabled = false
        bg.addSubview(delSel)
        conversationDeleteButton = delSel

        let countLabel = label(NSRect(x: 248, y: 22, width: 220, height: 20),
                               "", 12, .regular, .secondaryLabelColor)
        conversationCount = countLabel
        bg.addSubview(countLabel)

        let close = NSButton(frame: NSRect(x: w - 116, y: 18, width: 96, height: 30))
        close.title = "关闭"
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.target = self
        close.action = #selector(closeConversations)
        bg.addSubview(close)

        conversationWindow = win
        conversationTable = table
        conversationDetail = detail
    }

    private func reloadConversationWindow() {
        mainTableView?.reloadData()
        mainEmptyHint?.isHidden = !conversations.isEmpty
        conversationTable?.reloadData()
        conversationCount?.stringValue = "共 \(conversations.count) 条记录"
        refreshDeleteButtons()
    }

    // MARK: 删除对话记录

    /// 每次删除 / 清空前留一份完整备份，误删了也能找回来
    private func backupConversations() {
        let backup = kProject + "/conversations_backup.jsonl"
        guard let text = try? String(contentsOfFile: kConvoFile, encoding: .utf8),
              !text.isEmpty else { return }
        try? text.write(toFile: backup, atomically: true, encoding: .utf8)
    }

    /// 被删掉的记录单独留档，以后想找也找得到
    private func archiveDeleted(_ items: [Conversation]) {
        guard !items.isEmpty else { return }
        let path = kProject + "/deleted_conversations.jsonl"
        let enc = JSONEncoder()
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        for c in items {
            if let d = try? enc.encode(c), let s = String(data: d, encoding: .utf8) {
                text += s + "\n"
            }
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func persistConversations() {
        backupConversations()
        let enc = JSONEncoder()
        var text = ""
        for c in conversations {
            if let d = try? enc.encode(c), let s = String(data: d, encoding: .utf8) {
                text += s + "\n"
            }
        }
        try? text.write(toFile: kConvoFile, atomically: true, encoding: .utf8)
    }

    /// 删除只对当前前台的那张表生效；设置/日志窗口在前台时不会误删
    private func activeConversationTable() -> NSTableView? {
        let key = NSApp.keyWindow
        if key === conversationWindow, conversationWindow?.isVisible == true { return conversationTable }
        if key === window, window.isVisible { return mainTableView }
        // 焦点临时不在两张表上时，回退到「确实有选中行」的那张，避免按钮能点却删不掉
        if let c = conversationTable, conversationWindow?.isVisible == true,
           !c.selectedRowIndexes.isEmpty { return c }
        if let m = mainTableView, window.isVisible,
           !m.selectedRowIndexes.isEmpty { return m }
        return nil
    }

    private func refreshDeleteButtons() {
        mainDeleteButton?.isEnabled = !(mainTableView?.selectedRowIndexes.isEmpty ?? true)
        conversationDeleteButton?.isEnabled = !(conversationTable?.selectedRowIndexes.isEmpty ?? true)
    }

    @objc private func deleteSelectedConversations() {
        guard let table = activeConversationTable() else { return }
        let selected = table.selectedRowIndexes
        guard !selected.isEmpty else { return }
        // 列表是「最新在最上」，换成数组下标后倒序删，避免下标错位
        let indexes = selected.map { conversations.count - 1 - $0 }.sorted(by: >)
        let valid = indexes.filter { $0 >= 0 && $0 < conversations.count }
        archiveDeleted(valid.map { conversations[$0] })
        for idx in valid {
            conversations.remove(at: idx)
        }
        persistConversations()
        mainTableView?.deselectAll(nil)
        conversationTable?.deselectAll(nil)
        reloadConversationWindow()
        showConversationDetail(nil)
    }

    private func showConversationDetail(_ c: Conversation?) {
        guard let c = c else {
            conversationDetail?.string = "从左侧选择一条记录查看完整问答。"
            return
        }
        var s = "时间　\(c.time)\n\n"
        s += "【你问】\n\(c.question)\n\n"
        if !c.xiaoai.isEmpty { s += "【小爱原本的回答】\n\(c.xiaoai)\n\n" }
        s += "【\(c.model.isEmpty ? "大模型" : c.model) 的回答】\n\(c.answer)"
        conversationDetail?.string = s
    }

    func numberOfRows(in tableView: NSTableView) -> Int { conversations.count }

    func tableView(_ tableView: NSTableView,
                   viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < conversations.count else { return nil }
        let c = conversations[conversations.count - 1 - row]   // 最新在最上
        let id = column?.identifier.rawValue ?? ""
        let text: String
        switch id {
        case "time": text = c.time
        case "answer": text = c.answer.isEmpty ? "（无回答）" : c.answer
        default: text = c.question
        }
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = id == "answer" ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        // 首页列表单击只高亮，双击由 doubleAction 打开完整窗口
        if table === mainTableView {
            refreshDeleteButtons()
            return
        }
        let row = table.selectedRow
        if row >= 0, row < conversations.count {
            showConversationDetail(conversations[conversations.count - 1 - row])
        } else {
            showConversationDetail(nil)
        }
        refreshDeleteButtons()
    }

    // MARK: 模型 API 设置窗口

    private func currentConfig() -> (model: String, base: String, format: String, key: String) {
        let text = (try? String(contentsOfFile: kConfigFile, encoding: .utf8)) ?? ""
        var model = "LongCat-2.5"
        var base = "https://api.longcat.chat/openai/v1"
        var format = "chat"
        for raw in text.split(separator: "\n") {
            let t = String(raw).trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { continue }
            func val(_ prefix: String) -> String {
                var v = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return v
            }
            if t.hasPrefix("model:") {
                var v = val("model:")
                if let r = v.range(of: ":") { v = String(v[r.upperBound...]) }
                model = v
            } else if t.hasPrefix("api_base:") {
                base = val("api_base:")
            } else if t.hasPrefix("api_format:") {
                format = val("api_format:")
            }
        }
        return (model, base, format, keychainGet("XiaoAI-LLM-API-KEY"))
    }

    private func buildSettingsWindow() {
        let w: CGFloat = 560, h: CGFloat = 370
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "模型 API 设置"
        win.titlebarAppearsTransparent = true
        win.center()
        win.isReleasedWhenClosed = false

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .followsWindowActiveState
        win.contentView = bg

        bg.addSubview(label(NSRect(x: 28, y: 318, width: 504, height: 24),
                            "更换大模型 API", 17, .semibold, .labelColor))
        bg.addSubview(label(NSRect(x: 28, y: 294, width: 504, height: 18),
                            "支持任何 OpenAI 兼容接口。密钥只存入 macOS 钥匙串。", 11.5, .regular, .secondaryLabelColor))

        func rowLabel(_ y: CGFloat, _ text: String) {
            bg.addSubview(label(NSRect(x: 28, y: y + 4, width: 100, height: 20),
                                text, 12, .medium, .labelColor))
        }
        func field(_ y: CGFloat, _ placeholder: String) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 132, y: y, width: 400, height: 26))
            f.placeholderString = placeholder
            f.font = .systemFont(ofSize: 12)
            f.bezelStyle = .roundedBezel
            return f
        }

        rowLabel(258, "预设方案")
        fPreset = NSPopUpButton(frame: NSRect(x: 132, y: 254, width: 400, height: 28), pullsDown: false)
        fPreset.addItems(withTitles: ["LongCat（当前）", "DeepSeek", "自定义"])
        fPreset.target = self
        fPreset.action = #selector(presetChanged)
        bg.addSubview(fPreset)

        rowLabel(218, "模型名称")
        fModel = field(218, "例如 LongCat-2.5")
        bg.addSubview(fModel)

        rowLabel(178, "API 地址")
        fBase = field(178, "例如 https://api.longcat.chat/openai/v1")
        bg.addSubview(fBase)

        rowLabel(138, "API 密钥")
        fKey = NSSecureTextField(frame: NSRect(x: 132, y: 138, width: 290, height: 26))
        fKey.placeholderString = "ak_ 或 sk- 开头"
        fKey.font = .systemFont(ofSize: 12)
        fKey.bezelStyle = .roundedBezel
        bg.addSubview(fKey)

        // 同一位置放一个普通输入框：点「显示密钥」切过去，就能选中、复制出来核对
        fKeyPlain = field(138, "ak_ 或 sk- 开头")
        fKeyPlain.frame = NSRect(x: 132, y: 138, width: 290, height: 26)
        fKeyPlain.isHidden = true
        bg.addSubview(fKeyPlain)

        let reveal = NSButton(frame: NSRect(x: 430, y: 138, width: 102, height: 26))
        reveal.title = "显示密钥"
        reveal.bezelStyle = .rounded
        reveal.font = .systemFont(ofSize: 11.5)
        reveal.target = self
        reveal.action = #selector(toggleKeyVisible)
        reveal.toolTip = "显示后可直接全选、复制密钥；再点一次隐藏"
        bg.addSubview(reveal)
        fKeyRevealButton = reveal

        let test = NSButton(frame: NSRect(x: 28, y: 92, width: 110, height: 30))
        test.title = "测试连接"
        test.bezelStyle = .rounded
        test.target = self
        test.action = #selector(testConnection)
        bg.addSubview(test)

        fTestResult = label(NSRect(x: 148, y: 96, width: 384, height: 22),
                            "尚未测试", 11.5, .regular, .secondaryLabelColor)
        bg.addSubview(fTestResult)

        bg.addSubview(separator(80, w))

        let cancel = NSButton(frame: NSRect(x: w - 244, y: 26, width: 100, height: 30))
        cancel.title = "取消"
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(closeSettings)
        bg.addSubview(cancel)

        let save = NSButton(frame: NSRect(x: w - 136, y: 26, width: 108, height: 30))
        save.title = "保存并重启"
        save.bezelStyle = .rounded
        save.isBordered = true
        save.keyEquivalent = "\r"
        save.target = self
        save.action = #selector(saveSettings)
        bg.addSubview(save)

        settingsWindow = win
    }

    /// 不论当前显示的是隐藏框还是明文框，读到的都是同一个密钥
    private func currentKeyValue() -> String {
        keyRevealed ? fKeyPlain.stringValue : fKey.stringValue
    }

    @objc private func toggleKeyVisible() {
        keyRevealed.toggle()
        if keyRevealed {
            fKeyPlain.stringValue = fKey.stringValue
            fKey.isHidden = true
            fKeyPlain.isHidden = false
            fKeyRevealButton.title = "隐藏密钥"
            settingsWindow?.makeFirstResponder(fKeyPlain)
        } else {
            fKey.stringValue = fKeyPlain.stringValue
            fKeyPlain.isHidden = true
            fKey.isHidden = false
            fKeyRevealButton.title = "显示密钥"
            settingsWindow?.makeFirstResponder(fKey)
        }
    }

    private func fillSettings() {
        let cfg = currentConfig()
        fModel.stringValue = cfg.model
        fBase.stringValue = cfg.base
        fKey.stringValue = cfg.key
        fKeyPlain.stringValue = cfg.key
        keyRevealed = false
        fKey.isHidden = false
        fKeyPlain.isHidden = true
        fKeyRevealButton.title = "显示密钥"
        fTestResult.stringValue = "尚未测试"
        if cfg.base.contains("longcat") {
            fPreset.selectItem(at: 0)
        } else if cfg.base.contains("deepseek") {
            fPreset.selectItem(at: 1)
        } else {
            fPreset.selectItem(at: 2)
        }
    }

    private func testRequest(model: String, base: String, key: String) -> URLRequest? {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespaces) + "/chat/completions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "用一句话说：连接成功"]],
            "max_tokens": 300,
            "temperature": 0.7
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: 动作

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func restart() { startService() }

    @objc private func stop() {
        stopService()
        state = .stopped
        appendLog("=== \(todayString()) 已手动停止 ===\n")
    }

    // MARK: 运行日志窗口（按需打开，不再常驻首页）

    private func buildLogWindow() {
        let w: CGFloat = 760, h: CGFloat = 480
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "运行日志"
        win.titlebarAppearsTransparent = true
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 520, height: 340)

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .followsWindowActiveState
        win.contentView = bg

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 62, width: w - 40, height: h - 122))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: w - 40, height: h - 122))
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = tv
        bg.addSubview(scroll)
        logTextView = tv

        let refresh = NSButton(frame: NSRect(x: 20, y: 18, width: 88, height: 30))
        refresh.title = "刷新"
        refresh.bezelStyle = .rounded
        refresh.target = self
        refresh.action = #selector(refreshLog)
        bg.addSubview(refresh)

        let external = NSButton(frame: NSRect(x: 116, y: 18, width: 132, height: 30))
        external.title = "在控制台打开"
        external.bezelStyle = .rounded
        external.target = self
        external.action = #selector(openLog)
        bg.addSubview(external)

        let close = NSButton(frame: NSRect(x: w - 116, y: 18, width: 96, height: 30))
        close.title = "关闭"
        close.bezelStyle = .rounded
        close.target = self
        close.action = #selector(closeLogWindow)
        bg.addSubview(close)

        logWindow = win
    }

    private func refreshLogWindow() {
        let text = (try? String(contentsOfFile: kLogFile, encoding: .utf8)) ?? ""
        logTextView?.string = sanitize(text)
        logTextView?.scrollToEndOfDocument(nil)
    }

    @objc private func openLogWindow() {
        if logWindow == nil { buildLogWindow() }
        refreshLogWindow()
        NSApp.activate(ignoringOtherApps: true)
        logWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshLog() { refreshLogWindow() }
    @objc private func closeLogWindow() { logWindow?.orderOut(nil) }

    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: kLogFile)) }
    @objc private func openSetup() { NSWorkspace.shared.open(URL(fileURLWithPath: kSetupScript)) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openConversations() {
        if conversationWindow == nil { buildConversationWindow() }
        fillConversations()
        // 从首页双击某条记录进来时，完整窗口自动定位到同一条
        if let t = mainTableView, t.selectedRow >= 0, t.selectedRow < conversations.count {
            let row = t.selectedRow
            conversationTable?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            showConversationDetail(conversations[conversations.count - 1 - row])
        }
        NSApp.activate(ignoringOtherApps: true)
        conversationWindow?.makeKeyAndOrderFront(nil)
    }

    private func fillConversations() {
        loadConversations()
        reloadConversationWindow()
        showConversationDetail(conversations.last)
    }

    @objc private func closeConversations() { conversationWindow?.orderOut(nil) }

    @objc private func clearConversations() {
        let alert = NSAlert()
        alert.messageText = "清空所有对话记录？"
        alert.informativeText = "只会删除本机的对话预览记录，不影响音箱和模型配置。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        archiveDeleted(conversations)
        conversations = []
        persistConversations()
        reloadConversationWindow()
        showConversationDetail(nil)
    }

    @objc private func openSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        fillSettings()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // 光标直接落在模型名称框，打开就能 Cmd+V 粘贴
        settingsWindow?.makeFirstResponder(fModel)
    }

    @objc private func closeSettings() { settingsWindow?.orderOut(nil) }

    @objc private func presetChanged() {
        switch fPreset.indexOfSelectedItem {
        case 0:
            fModel.stringValue = "LongCat-2.5"
            fBase.stringValue = "https://api.longcat.chat/openai/v1"
        case 1:
            fModel.stringValue = "deepseek-flash"
            fBase.stringValue = "https://api.deepseek.com"
        default:
            break
        }
        fTestResult.stringValue = "预设已填入，请确认密钥后测试"
    }

    @objc private func testConnection() {
        let model = fModel.stringValue.trimmingCharacters(in: .whitespaces)
        let base = fBase.stringValue.trimmingCharacters(in: .whitespaces)
        let key = currentKeyValue().trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, !base.isEmpty, !key.isEmpty,
              let req = testRequest(model: model, base: base, key: key) else {
            fTestResult.stringValue = "请先把三项都填好"
            fTestResult.textColor = .systemRed
            return
        }
        fTestResult.stringValue = "正在测试…"
        fTestResult.textColor = .secondaryLabelColor
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.fTestResult.stringValue = "连接失败：\(error.localizedDescription)"
                    self.fTestResult.textColor = .systemRed
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                var reply = ""
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let msg = choices.first?["message"] as? [String: Any],
                   let content = msg["content"] as? String {
                    reply = String(content.prefix(24))
                }
                if code == 200 {
                    self.fTestResult.stringValue = "连接成功 · \(reply.isEmpty ? "HTTP 200" : reply)"
                    self.fTestResult.textColor = .systemGreen
                } else {
                    var detail = ""
                    if let data = data, let s = String(data: data, encoding: .utf8) {
                        detail = String(s.prefix(60))
                    }
                    self.fTestResult.stringValue = "HTTP \(code) · \(detail)"
                    self.fTestResult.textColor = .systemRed
                }
            }
        }.resume()
    }

    @objc private func saveSettings() {
        let model = fModel.stringValue.trimmingCharacters(in: .whitespaces)
        let base = fBase.stringValue.trimmingCharacters(in: .whitespaces)
        let key = currentKeyValue().trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, !base.isEmpty else {
            fTestResult.stringValue = "模型名称和 API 地址不能为空"
            fTestResult.textColor = .systemRed
            return
        }
        guard var text = try? String(contentsOfFile: kConfigFile, encoding: .utf8) else {
            fTestResult.stringValue = "找不到配置文件"
            fTestResult.textColor = .systemRed
            return
        }
        text = replaceConfigLine(text, #"^model:\s*.*$"#, "model: \"openai:\(model)\"")
        text = replaceConfigLine(text, #"^api_base:\s*.*$"#, "api_base: \"\(base)\"")
        text = replaceConfigLine(text, #"^api_format:\s*.*$"#, "api_format: chat")
        do {
            try text.write(toFile: kConfigFile, atomically: true, encoding: .utf8)
        } catch {
            fTestResult.stringValue = "写入配置失败：\(error.localizedDescription)"
            fTestResult.textColor = .systemRed
            return
        }
        if !key.isEmpty, !keychainSet("XiaoAI-LLM-API-KEY", key) {
            fTestResult.stringValue = "密钥写入钥匙串失败"
            fTestResult.textColor = .systemRed
            return
        }
        settingsWindow?.orderOut(nil)
        refreshModelLabel()
        appendLog("=== 已切换模型为 \(model)，正在重启服务 ===\n")
        notify("已切换到 \(model)，正在重新连接")
        startService()
    }

    // MARK: 开机自启

    private func autoLaunchEnabled() -> Bool {
        FileManager.default.fileExists(atPath: kPlistPath)
    }

    private func writeAutoPlist() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(kPlistLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>\(kAppPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """
        try? xml.write(toFile: kPlistPath, atomically: true, encoding: .utf8)
    }

    @objc private func toggleAuto() {
        if autoSwitch.state == .on {
            writeAutoPlist()
            _ = runSync("/bin/launchctl", ["unload", kOldPlist])
            let rc = runSync("/bin/launchctl", ["load", kPlistPath])
            if rc == 0 {
                appendLog("已开启开机自动启动\n")
                notify("已设置开机自动打开小爱助手")
            } else {
                appendLog("开机自启配置已写入，下次登录生效\n")
                let alert = NSAlert()
                alert.messageText = "开机自启没设上"
                alert.informativeText = "配置文件已放好，下次登录通常会生效。也可到「系统设置 → 通用 → 登录项」手动添加小爱助手。"
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        } else {
            _ = runSync("/bin/launchctl", ["unload", kPlistPath])
            try? FileManager.default.removeItem(atPath: kPlistPath)
            appendLog("已关闭开机自动启动\n")
        }
        refreshUI()
    }
}

// MARK: - 启动

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
