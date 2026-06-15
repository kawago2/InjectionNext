//
//  InjectionHybrid.swift
//  InjectionNext
//
//  Created by John Holdsworth on 09/11/2024.
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  Provide file watcher/log parser fallback
//  for use outside Xcode (e.g. Cursor/VSCode)
//  Also uses FileWatcher for operation when
//  swift-frontend has been replaced by a
//  script to capture compiler invocations.
//
import Cocoa

extension AppDelegate {
    static var watchers = [String: InjectionHybrid]()
    static var lastWatched: String?

    @IBAction func watchProject(_ sender: NSMenuItem) {
        let open = NSOpenPanel()
        open.prompt = "Select Project Directory"
        open.canChooseDirectories = true
        open.canChooseFiles = false
        // open.showsHiddenFiles = TRUE;
        if open.runModal() == .OK, let url = open.url {
            Reloader.xcodeDev = Defaults.xcodePath+"/Contents/Developer"
            watch(path: url.path)
        } else {
            Self.watchers.removeAll()
            Self.lastWatched = nil
        }
    }

    func watch(path: String, patchProjects: Bool = true) {
        guard Self.alreadyWatching(path) == nil else { return }
        for project in ProjectDiscovery.discoverProjects(in: path)
            where project.path.hasSuffix(".xcodeproj") && patchProjects {
            AppDelegate.ui.ensureInterposable(project: project.path)
        }
        GitIgnoreParser.monitor(directory: path)
        Self.watchers[path] = InjectionHybrid(watching: path)
        Self.lastWatched = path
        watchDirectoryItem.state = Self.watchers.isEmpty ? .off : .on
    }
    static func alreadyWatching(_ projectRoot: String) -> String? {
        return Self.watchers[projectRoot] != nil ? projectRoot :
            watchers.keys.first { projectRoot.hasPrefix($0+"/") }
    }
    static func restartLastWatcher() {
        DispatchQueue.main.async {
            lastWatched.flatMap { watchers[$0]?.watcher?.restart() }
        }
    }
}

class InjectionHybrid: InjectionBase {
    /// Last Injected for deduplication
    static var lastInjected = [String: TimeInterval]()
    /// Last queue of file changes
    static var pendingFilesChanged = [String]()
    /// Repository locked state - stops processing until app reconnects
    static var isRepositoryLocked = false
    /// Path to detected git lock file - used to check if git operation still active
    static var gitLockPath: String?
    /// InjectionNext compiler that uses InjectionLite log parser
    var logParsingCompiler: NextCompiler = HybridCompiler(name: "BuildLogs")
    /// Minimum seconds between injections
    let minInterval = 1.0

    var projectRootPath: String?

    init(watching path: String) { // FileWatcher compatibility
        self.projectRootPath = path
        let watchPaths = (getenv(INJECTION_DIRECTORIES) == nil ?
            NSHomeDirectory()+"/Library/Developer," : "") + path
        setenv(INJECTION_DIRECTORIES, watchPaths, 1)
        Reloader.injectionQueue = .main
        super.init()
        do {
            let customPattern = "(\(ConfigStore.shared.injectablePattern))|\\.xib$"
            FileWatcher.INJECTABLE_PATTERN = try NSRegularExpression(pattern: customPattern)
        } catch {
            InjectionServer.error("Invalid file pattern: \(error)")
        }
    }

    /// Called from file watcher when file is edited.
    override func inject(source: String) {
        // Detect git lock files - record path for later checking
        if source.hasSuffix(".lock") &&
           source.contains("/.git/") {
            Self.gitLockPath = source
            return
        }

        // Skip processing if repository is already locked
        if Self.isRepositoryLocked {
            log("""
                File processing stopped due to git lock. \
                Please relaunch your app to resume injection.
                """)
            return
        }

        // Check if source file is changing while git lock still exists
        if let lockPath = Self.gitLockPath {
            if FileManager.default.fileExists(atPath: lockPath) {
                // Source files changing while git lock exists = branch switch/merge/rebase
                Self.isRepositoryLocked = true
                Self.pendingFilesChanged.removeAll()
                Self.gitLockPath = nil
                log("""
                    Git operation in progress (branch switch/merge/rebase detected). \
                    File processing stopped. Please relaunch your app to resume injection.
                    """)
                return
            } else {
                // Lock file is gone - was probably just a commit
                Self.gitLockPath = nil
            }
        }

        if source.hasSuffix(".xib") {
            print("Custom Fork: Terdeteksi perubahan UI pada XIB -> \(source)")
            
            let targetAppName = self.determineAppName(for: source)
            print("Custom Fork: Mencari Simulator Bundle untuk -> \(targetAppName)")
            
            if let appPath = self.customFindSimulatorAppPath(appName: targetAppName), !appPath.isEmpty {
                let xibURL = URL(fileURLWithPath: source)
                let xibName = xibURL.lastPathComponent
                let nibName = xibName.replacingOccurrences(of: ".xib", with: ".nib")
                let targetNibPath = self.findExistingNibPath(in: appPath, nibName: nibName) ?? "\(appPath)/\(nibName)"
                
                print("Custom Fork: Mengompilasi \(xibName) ke Simulator...")
                if self.customCompileXib(xibPath: source, targetNibPath: targetNibPath) {
                    print("Custom Fork: NIB Berhasil disuntikkan!")
                    
                    for client in InjectionServer.currentClients {
                        client?.sendCommand(.reloadXIB, with: nibName.replacingOccurrences(of: ".nib", with: ""))
                    }
                    
                    let swiftPath = source.replacingOccurrences(of: ".xib", with: ".swift")
                    if FileManager.default.fileExists(atPath: swiftPath) {
                        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: swiftPath)
                    }
                }
            } else {
                print("Custom Fork: Gagal menemukan bundle \(targetAppName) di Simulator. Apakah app sudah running?")
            }
            return
        }

        let now = Date.timeIntervalSinceReferenceDate
        guard !AppDelegate.watchers.isEmpty, now - (
                Self.lastInjected[source] ?? 0.0) > minInterval else {
            return
        }
        Self.lastInjected[source] = now

        Self.pendingFilesChanged.append(source)
        NextCompiler.compileQueue.async {
            self.injectNext()
        }
    }

    func injectNext() {
        guard let source = (DispatchQueue.main.sync { () -> String? in
            guard let source = Self.pendingFilesChanged.first else { return nil }
            Self.pendingFilesChanged.removeAll(where: { $0 == source })
            if !Self.pendingFilesChanged.isEmpty {
                NextCompiler.compileQueue.async { self.injectNext() }
            }
            return source
        }) else { return }

        autoreleasepool {
        var recompiler = MonitorXcode.recompiler
        let platform = FrontendServer.clientPlatform
        if recompiler.canCompile(source: source, for: platform),
           recompiler.inject(source: source) { return }

        recompiler = logParsingCompiler
        if source.hasSuffix(".swift") &&
            AppDelegate.ui.updatePatchUnpatch() == .patched {
            let proxyCompiler = FrontendServer.frontendRecompiler(for: platform)
            if proxyCompiler.canCompile(source: source) {
                recompiler = proxyCompiler
            }
        }

        if !Defaults.ignoreGitignore,
           let why = GitIgnoreParser.shouldExclude(file: source) {
            log("Excluded \(source) as \(why)")
        } else if !recompiler.inject(source: source) {
            recompiler.pendingSource = source
        }
        }
    }
}

class HybridCompiler: NextCompiler {
    /// Legacy log parsing version of recomilation
    static var liteRecompiler = Recompiler()

    override func recompile(source: String, platform: String) ->  String? {
        let connected = InjectionServer.currentClient  != nil,
            oldCache = Reloader.cacheFile
        Reloader.sdk = platform // Switch commands cache file.
        if oldCache != Reloader.cacheFile && connected {
            Self.liteRecompiler = Recompiler()
        }
        return Self.liteRecompiler.recompile(source: source, platformFilter:
                            connected ? "SDKs/"+platform : "", dylink: false)
    }

    override func link(object: String, dylib: String, arch: String) -> (String, Double)? {
        return super.link(object: object, dylib: dylib, arch: arch) ??
                                   Self.liteRecompiler.linkingFailed()
    }
}

extension InjectionHybrid {
    
    func determineAppName(for source: String) -> String {
        if Reloader.appName != "Unknown" && !Reloader.appName.isEmpty {
            return Reloader.appName + ".app"
        }
        
        var dir = URL(fileURLWithPath: source).deletingLastPathComponent()
        while dir.path != "/" {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                if let xcodeProj = files.first(where: { $0.hasSuffix(".xcodeproj") }) {
                    return xcodeProj.replacingOccurrences(of: ".xcodeproj", with: ".app")
                }
                if files.contains("project.yml") {
                    let folderName = dir.lastPathComponent
                    return "\(folderName).app"
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        
        guard let root = self.projectRootPath else { return "*.app" }
        
        if let files = try? FileManager.default.contentsOfDirectory(atPath: root),
           let xcodeProj = files.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return xcodeProj.replacingOccurrences(of: ".xcodeproj", with: ".app")
        }
        
        let folderName = URL(fileURLWithPath: root).lastPathComponent
        return "\(folderName).app"
    }
    
    func customFindSimulatorAppPath(appName: String) -> String? {
        let cmd = "find ~/Library/Developer/CoreSimulator/Devices/ -name \"\(appName)\" -print0 2>/dev/null | xargs -0 stat -f \"%m %N\" 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", cmd]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
    
    func customCompileXib(xibPath: String, targetNibPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ibtool")
        process.arguments = ["--compile", targetNibPath, xibPath]
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    func findExistingNibPath(in appPath: String, nibName: String) -> String? {
        let fileManager = FileManager.default
        let appURL = URL(fileURLWithPath: appPath)
        
        if let enumerator = fileManager.enumerator(at: appURL, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == nibName {
                    return fileURL.path
                }
            }
        }
        return nil
    }
}
