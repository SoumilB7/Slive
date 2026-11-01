import Foundation

/// Where the transcription layer reports real faults — `FailureReporter` in
/// the app, a recorder in the self-tests. Keeps the caller's file/line, which
/// the report shows as its source.
struct FaultSink {
    let send: (_ area: String, _ title: String, _ error: Error?, _ detail: String?,
               _ file: String, _ line: Int, _ function: String) -> Void

    func callAsFunction(_ area: String, _ title: String, error: Error? = nil, detail: String? = nil,
                        file: String = #fileID, line: Int = #line, function: String = #function) {
        send(area, title, error, detail, file, line, function)
    }

    static let app = FaultSink { area, title, error, detail, file, line, function in
        FailureReporter.shared.report(area, title, error: error, detail: detail,
                                      file: file, line: line, function: function)
    }
}
