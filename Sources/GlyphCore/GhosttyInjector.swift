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

public struct GhosttyInjector: Sendable {
    public static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
    public static let handlerName = "injectText"

    public static let scriptSource = """
    on \(handlerName)(payload)
        tell application id "\(ghosttyBundleIdentifier)"
            set term to focused terminal of selected tab of front window
            input text payload to term
        end tell
        return "ok"
    end \(handlerName)
    """

    public init() {}

    public func inject(_ text: String) throws {
        guard let script = NSAppleScript(source: Self.scriptSource) else {
            throw GhosttyInjectorError.compileFailed("Could not create NSAppleScript.")
        }

        var compileError: NSDictionary?
        guard script.compileAndReturnError(&compileError) else {
            throw GhosttyInjectorError.compileFailed(Self.errorMessage(from: compileError))
        }

        var executionError: NSDictionary?
        let result = script.executeAppleEvent(Self.eventDescriptor(for: text), error: &executionError)

        guard executionError == nil else {
            throw GhosttyInjectorError.executionFailed(Self.errorMessage(from: executionError))
        }

        guard result.stringValue == "ok" else {
            throw GhosttyInjectorError.noResult
        }
    }

    public static func eventDescriptor(for text: String) -> NSAppleEventDescriptor {
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
