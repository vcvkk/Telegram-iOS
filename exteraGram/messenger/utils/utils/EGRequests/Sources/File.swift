import Foundationimport SwiftSignalKit
private final class EGSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// Dedicated session so Telegram's shared-session configuration cannot interfere.
private let egSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    return URLSession(configuration: config, delegate: EGSessionDelegate(), delegateQueue: nil)
}()


public func requestsDownload(url: URL) -> Signal<(Data, URLResponse?), Error?> {
    return Signal { subscriber in
        let completed = Atomic<Bool>(value: false)

        let downloadTask = egSession.downloadTask(with: url, completionHandler: { location, response, error in
            let _ = completed.swap(true)
            if let location = location, let data = try? Data(contentsOf: location) {
                subscriber.putNext((data, response))
                subscriber.putCompletion()
            } else {
                subscriber.putError(error)
            }
        })
        downloadTask.resume()

        return ActionDisposable {
            if !completed.with({ $0 }) {
                downloadTask.cancel()
            }
        }
    }
}

public func requestsGet(url: URL) -> Signal<(Data, URLResponse?), Error?> {
    return Signal { subscriber in
        let completed = Atomic<Bool>(value: false)

        let urlTask = egSession.dataTask(with: url, completionHandler: { data, response, error in
            let _ = completed.swap(true)
            if let strongData = data {
                subscriber.putNext((strongData, response))
                subscriber.putCompletion()
            } else {
                subscriber.putError(error)
            }
        })
        urlTask.resume()

        return ActionDisposable {
            if !completed.with({ $0 }) {
                urlTask.cancel()
            }
        }
    }
}


public func requestsCustom(request: URLRequest) -> Signal<(Data, URLResponse?), Error?> {
    return Signal { subscriber in
        let completed = Atomic<Bool>(value: false)
        let urlTask = egSession.dataTask(with: request, completionHandler: { data, response, error in
            _ = completed.swap(true)
            if let strongData = data {
                subscriber.putNext((strongData, response))
                subscriber.putCompletion()
            } else {
                subscriber.putError(error)
            }
        })
        urlTask.resume()

        return ActionDisposable {
            if !completed.with({ $0 }) {
                urlTask.cancel()
            }
        }
    }
}
