import Foundation

/// Finder "Quick Action" workflows (right click > Azioni rapide). Each one just opens
/// `fcptoolbox://tool/<id>?file=...` with the selected files; the app does the rest.
public enum QuickActions {
    public static let prefix = "FCP Toolbox - "
    static let marker = "FCPToolboxQuickAction"
    public static let bundleID = "app.fcptoolbox"

    public struct Action: Equatable, Sendable {
        public let toolID: String   // a catalog id, or DeepLink.dropID
        public let name: String     // as shown in the Finder menu
        public var fileName: String { name + ".workflow" }
    }

    public static let actions: [Action] = [
        Action(toolID: DeepLink.dropID, name: prefix + "Cosa posso fare con questo file"),
        Action(toolID: "convert.compress", name: prefix + "Riduci il peso"),
        Action(toolID: "convert.audio", name: prefix + "Estrai audio"),
        Action(toolID: "info", name: prefix + "Info file"),
        Action(toolID: "contact", name: prefix + "Foglio provini"),
        Action(toolID: "metadata", name: prefix + "Pulisci metadata"),
        Action(toolID: "subtitles", name: prefix + "Controlla sottotitoli"),
    ]

    /// Bash run by the workflow with the selected paths as arguments. `openCommand` is replaceable for tests.
    static func script(toolID: String, openCommand: String = "/usr/bin/open") -> String {
        """
        url="fcptoolbox://tool/\(toolID)?"; sep=""
        for f in "$@"; do
          enc=$(printf '%s' "$f" | /usr/bin/perl -pe 's/([^A-Za-z0-9_.~\\/-])/sprintf("%%%02X",ord($1))/ge')
          url="${url}${sep}file=${enc}"; sep="&"
        done
        \(openCommand) -b \(bundleID) "$url"
        """
    }

    static func infoPlist(_ a: Action) -> [String: Any] {
        [
            "CFBundleName": a.name,
            marker: true,
            "NSServices": [[
                "NSBackgroundColorName": "background",
                "NSIconName": "NSActionTemplate",
                "NSMenuItem": ["default": a.name],
                "NSMessage": "runWorkflowAsService",
                "NSRequiredContext": ["NSApplicationIdentifier": "com.apple.finder"],
                "NSSendFileTypes": ["public.item"],
            ]],
        ]
    }

    static func workflow(_ a: Action, script: String) -> [String: Any] {
        let action: [String: Any] = [
            "action": [
                "AMAccepts": ["Container": "List", "Optional": true, "Types": ["com.apple.cocoa.string"]],
                "AMActionVersion": "2.0.3",
                "AMApplication": ["Automator"],
                "AMParameterProperties": ["COMMAND_STRING": [String: Any](), "CheckedForUserDefaultShell": [String: Any](),
                                          "inputMethod": [String: Any](), "shell": [String: Any](), "source": [String: Any]()],
                "AMProvides": ["Container": "List", "Types": ["com.apple.cocoa.string"]],
                "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
                "ActionName": "Run Shell Script",
                "ActionParameters": ["COMMAND_STRING": script, "CheckedForUserDefaultShell": true,
                                     "inputMethod": 1, "shell": "/bin/bash", "source": ""],
                "BundleIdentifier": "com.apple.RunShellScript",
                "CFBundleVersion": "2.0.3",
                "CanShowSelectedItemsWhenRun": false,
                "CanShowWhenRun": true,
                "Category": ["AMCategoryUtilities"],
                "Class Name": "RunShellScriptAction",
                "InputUUID": UUID().uuidString,
                "Keywords": ["Shell", "Script", "Command", "Run", "Unix"],
                "OutputUUID": UUID().uuidString,
                "UUID": UUID().uuidString,
                "UnlocalizedApplications": ["Automator"],
                "arguments": [String: Any](),
                "isViewVisible": true,
                "location": "309.000000:253.000000",
                "nibPath": "/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib",
            ] as [String: Any]
        ]
        return [
            "AMApplicationBuild": "523",
            "AMApplicationVersion": "2.10",
            "AMDocumentVersion": "2",
            "actions": [action],
            "connectors": [String: Any](),
            "workflowMetaData": [
                "applicationBundleIDsByPath": [String: Any](),
                "applicationPaths": [String](),
                "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "outputTypeIdentifier": "com.apple.Automator.nothing",
                "presentationMode": 15,
                "processesInput": false,
                "serviceApplicationBundleID": "com.apple.finder",
                "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
                "serviceProcessesInput": false,
                "systemImageName": "NSActionTemplate",
                "useAutomaticInputType": false,
                "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
            ] as [String: Any],
        ]
    }

    private static func write(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// Default place where macOS looks for Quick Actions.
    public static var servicesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services")
    }

    /// Writes the workflow bundles into `folder` (replacing ours of the same name); returns what was created.
    @discardableResult
    public static func install(into folder: URL = servicesFolder, openCommand: String = "/usr/bin/open") throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var made: [URL] = []
        for a in actions {
            let bundle = folder.appendingPathComponent(a.fileName)
            if fm.fileExists(atPath: bundle.path) {
                // never replace something that is not ours
                guard isOurs(bundle) else { continue }
                try fm.removeItem(at: bundle)
            }
            let contents = bundle.appendingPathComponent("Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            try write(infoPlist(a), to: contents.appendingPathComponent("Info.plist"))
            try write(workflow(a, script: script(toolID: a.toolID, openCommand: openCommand)), to: contents.appendingPathComponent("document.wflow"))
            made.append(bundle)
        }
        return made
    }

    static func isOurs(_ bundle: URL) -> Bool {
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: info) else { return false }
        return d[marker] as? Bool == true
    }

    /// Our workflows currently present in `folder`.
    public static func installed(in folder: URL = servicesFolder) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "workflow" && isOurs($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Removes only the workflows this app created (recognised by the marker key).
    @discardableResult
    public static func remove(from folder: URL = servicesFolder) throws -> [URL] {
        let ours = installed(in: folder)
        for u in ours { try FileManager.default.removeItem(at: u) }
        return ours
    }
}
