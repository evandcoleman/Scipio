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

        internalDelegate?.downloadRequests[url] = (progressHandler, completionHandler)

        return downloadTask(with: url)
    }

    func uploadTask(with request: URLRequest, fromFile file: URL, progressHandler: @escaping (Double) -> Void, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionUploadTask {

        internalDelegate?.uploadRequests[request.url!] = (progressHandler, completionHandler)

        return uploadTask(with: request, fromFile: file)
    }
}

private final class Delegate: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate {

    let operationQueue = OperationQueue()

    var downloadRequests: [URL: (progressHandler: (Double) -> Void, completionHandler: (URL?, URLResponse?, Error?) -> Void)] = [:]
    var uploadRequests: [URL: (progressHandler: (Double) -> Void, completionHandler: (Data?, URLResponse?, Error?) -> Void)] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let url = downloadTask.originalRequest?.url,
           let (progressHandler, _) = downloadRequests[url] {

            progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let url = downloadTask.originalRequest?.url,
           let (progressHandler, completionHandler) = downloadRequests[url] {

            progressHandler(1)
            completionHandler(location, downloadTask.response, downloadTask.error)
            downloadRequests.removeValue(forKey: url)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if let url = task.originalRequest?.url,
           let (progressHandler, _) = uploadRequests[url] {

            progressHandler(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let url = task.originalRequest?.url,
           let (_, completionHandler) = uploadRequests[url] {

            completionHandler(nil, task.response, error)
            uploadRequests.removeValue(forKey: url)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let url = dataTask.originalRequest?.url,
           let (progressHandler, completionHandler) = uploadRequests[url] {

            progressHandler(1)
            completionHandler(data, dataTask.response, nil)
            uploadRequests.removeValue(forKey: url)
        }
    }
}
