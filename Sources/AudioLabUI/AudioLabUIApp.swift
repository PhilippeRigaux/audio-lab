import AppKit
import SwiftUI
import Foundation
import Darwin

extension Notification.Name {
    static let audioLabTerminateRequested = Notification.Name("AudioLabTerminateRequested")
    static let audioLabTerminateReady = Notification.Name("AudioLabTerminateReady")
}

@main
struct AudioLabUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Audio Lab") {
            ContentView()
                .frame(minWidth: 1420, minHeight: 760)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var relaunchTerminationBypass = false
    private var terminationReplyPending = false
    private var terminationTimeoutWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if BundleHostRelauncher.relaunchIfNeeded() {
            relaunchTerminationBypass = true
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyWindowSizeConstraints),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        applyWindowSizeConstraints()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminateReady),
            name: .audioLabTerminateReady,
            object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if relaunchTerminationBypass {
            return .terminateNow
        }
        if terminationReplyPending {
            return .terminateLater
        }

        terminationReplyPending = true
        NotificationCenter.default.post(name: .audioLabTerminateRequested, object: nil)

        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self, self.terminationReplyPending else { return }
            self.terminationReplyPending = false
            NSApp.reply(toApplicationShouldTerminate: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                Darwin.exit(0)
            }
        }
        terminationTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: timeoutWork)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationTimeoutWorkItem?.cancel()
        terminationTimeoutWorkItem = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleTerminateReady() {
        guard terminationReplyPending else { return }
        terminationReplyPending = false
        terminationTimeoutWorkItem?.cancel()
        terminationTimeoutWorkItem = nil
        NSApp.reply(toApplicationShouldTerminate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Darwin.exit(0)
        }
    }

    @objc private func applyWindowSizeConstraints() {
        for window in NSApp.windows {
            guard window.title == "Audio Lab" else { continue }
            let minHeight: CGFloat = 760
            let minWidth: CGFloat = 1420
            window.contentMinSize = NSSize(width: minWidth, height: minHeight)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }
}

private enum BundleHostRelauncher {
    private static let relaunchEnv = "AUDIO_LAB_BUNDLE_RELAUNCHED"
    private static let appName = "Audio Lab"
    private static let bundleID = "com.audiolab.ui"
    private static let executableName = "audio-lab-ui"

    static func relaunchIfNeeded() -> Bool {
        if ProcessInfo.processInfo.environment[relaunchEnv] == "1" {
            return false
        }

        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty, Bundle.main.bundleURL.pathExtension == "app" {
            return false
        }

        do {
            let appExecURL = try prepareAppBundle()
            let process = Process()
            process.executableURL = appExecURL
            process.arguments = Array(CommandLine.arguments.dropFirst())
            var env = ProcessInfo.processInfo.environment
            env[relaunchEnv] = "1"
            process.environment = env
            try process.run()
            return true
        } catch {
            NSLog("Bundle relaunch failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func prepareAppBundle() throws -> URL {
        let fm = FileManager.default
        let appSupportDir = try fm.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true)
        let rootDir = appSupportDir.appendingPathComponent("AudioLab", isDirectory: true)
        let appDir = rootDir.appendingPathComponent("\(appName).app", isDirectory: true)
        let contentsDir = appDir.appendingPathComponent("Contents", isDirectory: true)
        let macOSDir = contentsDir.appendingPathComponent("MacOS", isDirectory: true)
        let plistURL = contentsDir.appendingPathComponent("Info.plist", isDirectory: false)
        let execURL = macOSDir.appendingPathComponent(executableName, isDirectory: false)

        try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true)

        let sourceExec = URL(fileURLWithPath: CommandLine.arguments[0])
        if fm.fileExists(atPath: execURL.path) {
            try fm.removeItem(at: execURL)
        }
        try fm.copyItem(at: sourceExec, to: execURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

        let plist: [String: Any] = [
            "CFBundleName": appName,
            "CFBundleDisplayName": appName,
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": executableName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        return execURL
    }
}
