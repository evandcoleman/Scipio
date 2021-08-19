import Foundation

private var internalDelegateKey: UInt8 = 0

extension URLSession {

    private var internalDelegate: Delegate? {
        get { objc_getAssociatedObject(self, &internalDelegateKey) as? Delegate }
        set { objc_setAssociatedObject(self, &internalDelegateKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    static func createWithExtensionsSupport() -> URLSession {
        let delegate = Delegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: delegate.operationQueue)
        session.internalDelegate = delegate
        return session
    }

    func downloadTask(with url: URL, progressHandler: @escaping (Double) -> Void, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {

        internalDelegate?.requests[url] = (progressHandler, completionHandler)

        return downloadTask(with: url)
    }
}

private final class Delegate: NSObject, URLSessionDownloadDelegate {

    let operationQueue = OperationQueue()

    var requests: [URL: (progressHandler: (Double) -> Void, completionHandler: (URL?, URLResponse?, Error?) -> Void)] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let url = downloadTask.originalRequest?.url,
           let (progressHandler, _) = requests[url] {

            progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let url = downloadTask.originalRequest?.url,
           let (progressHandler, completionHandler) = requests[url] {

            progressHandler(1)
            completionHandler(location, downloadTask.response, downloadTask.error)
            requests.removeValue(forKey: url)
        }
    }
}
