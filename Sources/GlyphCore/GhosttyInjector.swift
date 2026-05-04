import Carbon
import Foundation

public enum GhosttyInjectorError: Error, LocalizedError, Sendable {
    case compileFailed(String)
    case executionFailed(String)
    case noResult

    public var errorDescription: String? {
        switch self {
        case .compileFailed(let message):
            "Ghostty injection script failed to compile: \(message)"
        case .executionFailed(let message):
            "Ghostty injection failed: \(message)"
        case .noResult:
            "Ghostty injection did not return a result."
        }
    }
}

public final class GhosttyInjector: @unchecked Sendable {
    public static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
    public static let handlerName = "injectText"

    public static let scriptSource = """
    on \(handlerName)(payload, shouldSubmit)
        tell application id "\(ghosttyBundleIdentifier)"
            activate
            set term to focused terminal of selected tab of front window
            input text payload to term
        end tell
        if shouldSubmit then
            delay 0.05
            tell application "System Events" to key code 36
        end if
        return "ok"
    end \(handlerName)
    """

    private let lock = NSLock()
    private var compiledScript: NSAppleScript?

    public init() {}

    public func prepare() throws {
        lock.lock()
        defer {
            lock.unlock()
        }

        _ = try script()
    }

    public func inject(_ text: String, submit: Bool = false) throws {
        lock.lock()
        defer {
            lock.unlock()
        }

        let script = try script()
        var executionError: NSDictionary?
        let result = script.executeAppleEvent(Self.eventDescriptor(for: text, submit: submit), error: &executionError)

        guard executionError == nil else {
            throw GhosttyInjectorError.executionFailed(Self.errorMessage(from: executionError))
        }

        guard result.stringValue == "ok" else {
            throw GhosttyInjectorError.noResult
        }
    }

    private func script() throws -> NSAppleScript {
        if let compiledScript {
            return compiledScript
        }

        guard let script = NSAppleScript(source: Self.scriptSource) else {
            throw GhosttyInjectorError.compileFailed("Could not create NSAppleScript.")
        }

        var compileError: NSDictionary?
        guard script.compileAndReturnError(&compileError) else {
            throw GhosttyInjectorError.compileFailed(Self.errorMessage(from: compileError))
        }

        compiledScript = script
        return script
    }

    public static func eventDescriptor(for text: String, submit: Bool = false) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handlerName), forKeyword: AEKeyword(keyASSubroutineName))

        let parameters = NSAppleEventDescriptor.list()
        parameters.insert(NSAppleEventDescriptor(string: text), at: 1)
        parameters.insert(NSAppleEventDescriptor(boolean: submit), at: 2)
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))

        return event
    }

    private static func errorMessage(from errorInfo: NSDictionary?) -> String {
        guard let errorInfo else {
            return "Unknown AppleScript error."
        }

        let message = errorInfo[NSAppleScript.errorMessage] as? String
            ?? errorInfo[NSAppleScript.errorBriefMessage] as? String
            ?? "\(errorInfo)"

        return TranscriptionCleaner.clean(message)
    }
}
