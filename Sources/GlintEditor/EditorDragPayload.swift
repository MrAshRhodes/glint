import AppKit
import GlintCore
import UniformTypeIdentifiers

/// The image the editor's "Drag to share" tile carries.
///
/// The drag starts at once. From that moment the image is rendered and written to a cache file in the background,
/// and a destination takes it in whichever way it understands:
///
/// - as a file promise, which Finder, Mail and other native apps use: they ask for the file when it is dropped and it
///   is written where they say, or
/// - as the cache file's URL, handed out when a destination reads it, which is what Chromium and Electron based apps
///   need because they only accept real file URLs.
///
/// Both wait for the background work, never the drag itself. When the work fails nothing is handed out, so a
/// redaction that could not be applied never reaches a destination.
final class EditorDragPayload: NSFilePromiseProvider {
    /// The file the drag carries and the image written to it.
    struct Delivery: @unchecked Sendable {
        let url: URL
        let image: CGImage
    }

    typealias Build = @Sendable () throws -> Delivery

    // AppKit calls `init()` from inside `init(fileType:delegate:)`. A designated initializer declared here would
    // replace the inherited `init()` with one that traps, so the class declares none, gives every property a
    // default and is created through the convenience initializer below. An instance made through an inherited
    // initializer carries nothing and says so, instead of making a destination wait for work that never starts.
    private var outcome = Outcome(.failure(CocoaError(.fileNoSuchFile)))
    private var promiseDelegate: PromiseDelegate?

    /// A file to remove once nothing holds this payload any more. Set when the window that made the drag closed
    /// before the file existed, so its clean-up missed it while a destination may still be about to read it.
    var removeFileWhenReleased: URL?

    deinit {
        if let url = removeFileWhenReleased { try? FileManager.default.removeItem(at: url) }
    }

    /// Starts `build` on a background queue right away.
    convenience init(fileName: String, build: @escaping Build) {
        let outcome = Outcome()
        let delegate = PromiseDelegate(fileName: fileName, outcome: outcome)
        self.init(fileType: UTType.png.identifier, delegate: delegate)
        self.outcome = outcome
        self.promiseDelegate = delegate
        DispatchQueue.global(qos: .userInitiated).async { outcome.complete(Result { try build() }) }
    }

    /// Waits until the file exists or the work failed. Never call it from the work itself.
    func waitForDelivery() -> Result<Delivery, Error> {
        outcome.wait()
    }

    /// The same outcome, without holding a thread of the caller.
    func delivery() async -> Result<Delivery, Error> {
        await withCheckedContinuation { continuation in
            outcome.notify { continuation.resume(returning: $0) }
        }
    }

    // MARK: NSPasteboardWriting

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.fileURL]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .fileURL ? .promised : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == .fileURL else { return super.pasteboardPropertyList(forType: type) }
        guard case .success(let delivery) = outcome.wait() else { return nil }
        return (delivery.url as NSURL).pasteboardPropertyList(forType: type)
    }

    // MARK: Pieces

    /// The result of the background work, which anything may wait for or be told about.
    private final class Outcome: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Result<Delivery, Error>?
        private var observers: [(Result<Delivery, Error>) -> Void] = []

        init(_ result: Result<Delivery, Error>? = nil) {
            self.result = result
        }

        func complete(_ value: Result<Delivery, Error>) {
            condition.lock()
            result = value
            let pending = observers
            observers = []
            condition.broadcast()
            condition.unlock()
            for observer in pending { observer(value) }
        }

        func wait() -> Result<Delivery, Error> {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let result { return result }
                condition.wait()
            }
        }

        func notify(_ observer: @escaping (Result<Delivery, Error>) -> Void) {
            condition.lock()
            guard let result else {
                observers.append(observer)
                condition.unlock()
                return
            }
            condition.unlock()
            observer(result)
        }
    }

    /// Answers the destination's promise requests on a background queue, so a destination that is waiting for the
    /// file never waits for the main thread.
    private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
        private let fileName: String
        private let outcome: Outcome
        private let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "glint.editor.drag-promise"
            queue.qualityOfService = .userInitiated
            return queue
        }()

        init(fileName: String, outcome: Outcome) {
            self.fileName = fileName
            self.outcome = outcome
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            fileName
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            switch outcome.wait() {
            case .success(let delivery):
                do {
                    try Data(contentsOf: delivery.url, options: .mappedIfSafe).write(to: url, options: .atomic)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            case .failure(let error):
                completionHandler(error)
            }
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
    }
}
