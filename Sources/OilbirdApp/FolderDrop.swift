import AppKit
import WebKit

/// Dropping a folder on Oilbird scans it.
///
/// ⚠ The window used to call `web.registerForDraggedTypes([.fileURL])` under
/// a comment saying a dropped folder is a scan, and nothing anywhere
/// implemented the destination protocol. Registering a type is a promise to
/// AppKit that this view will answer; the drag was therefore accepted,
/// highlighted, and then handled by WKWebView's own default behaviour, which
/// is not a scan. Dropping a folder to scan it is meant to work, so it is
/// implemented rather than the promise withdrawn.
///
/// Two destinations, because the window is two things: the web view covers
/// most of it once a dashboard has loaded, and Oilbird's own ground covers
/// the rest. A drop that works on the empty state and dies over the
/// dashboard would be worse than none — the user would learn a gesture that
/// stops working as soon as they have something to look at.
enum FolderDrop {
    /// The one folder in this drag, or nil.
    ///
    /// Exactly one, and it must be a directory. `scan` takes a single
    /// project directory: a file is not a project, and five folders is not
    /// one. Both are refused at `draggingEntered`, so the cursor never
    /// promises something the drop cannot do.
    static func folder(in sender: NSDraggingInfo) -> URL? {
        let urls =
            sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard urls.count == 1, let url = urls.first else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
            directory.boolValue
        else { return nil }
        return url
    }
}

/// Oilbird's own ground, as a drag destination.
final class FolderDropView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        FolderDrop.folder(in: sender) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        FolderDrop.folder(in: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let folder = FolderDrop.folder(in: sender) else { return false }
        onDrop?(folder)
        return true
    }
}

/// SonarQube's page, with one gesture of Oilbird's kept in front of it.
///
/// The dashboard is Sonar's and Oilbird adds no chrome inside it, but a
/// folder dragged onto the window is not a message to the page — it is a
/// scan, and the page has no idea what to do with it. Anything that is not
/// a single folder falls straight through to WebKit's own handling, so text
/// and links dragged into the dashboard behave exactly as they did.
final class DashboardWebView: WKWebView {
    var onFolderDrop: ((URL) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard FolderDrop.folder(in: sender) != nil else { return super.draggingEntered(sender) }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard FolderDrop.folder(in: sender) != nil else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let folder = FolderDrop.folder(in: sender) else {
            return super.performDragOperation(sender)
        }
        onFolderDrop?(folder)
        return true
    }
}
