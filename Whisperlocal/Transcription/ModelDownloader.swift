import Foundation

@MainActor
final class ModelDownloader: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case finished
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var session: URLSession!
    private var task: URLSessionDownloadTask?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start() {
        guard case .idle = state else { return }
        state = .downloading(progress: 0)
        let task = session.downloadTask(with: ModelStore.remoteURL)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0
            ? Double(totalBytesExpectedToWrite)
            : Double(ModelStore.approxBytes)
        let p = min(1.0, Double(totalBytesWritten) / expected)
        Task { @MainActor in
            self.state = .downloading(progress: p)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let destination = ModelStore.downloadedURL()
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in self.state = .finished }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in self.state = .failed(message) }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        let message = error.localizedDescription
        Task { @MainActor in self.state = .failed(message) }
    }
}
