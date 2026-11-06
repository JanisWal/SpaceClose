import Foundation

enum PermissionRecovery: Equatable {
    case ready, grantNeeded, restartNeeded, restartAlreadyTried, checkFailed
    static func decide(localTrusted: Bool, freshExitCode: Int32?, didRestart: Bool) -> PermissionRecovery {
        if localTrusted { return .ready }
        switch freshExitCode {
        case 0: return didRestart ? .restartAlreadyTried : .restartNeeded
        case 3: return .grantNeeded
        default: return .checkFailed
        }
    }
}

// A fresh process reads its own TCC status. Its result must never be used to
// pretend the GUI process has access: a mismatch requires a real app restart.
final class FreshPermissionProbe {
    private var task: Process?
    var running: Bool { task != nil }
    func run(executable: URL, completion: @escaping (Int32?) -> Void) {
        guard task == nil else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--permission-status"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.task === finished else { return }
                self.task = nil
                completion(finished.terminationReason == .exit ? finished.terminationStatus : nil)
            }
        }
        task = process
        do { try process.run() }
        catch { task = nil; completion(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.task === process else { return }
            self.task = nil
            if process.isRunning { process.terminate() }
            completion(nil)
        }
    }
    func cancel() {
        let process = task
        task = nil
        if process?.isRunning == true { process?.terminate() }
    }
}
