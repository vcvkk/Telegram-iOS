import Foundation
import SwiftSignalKit

import EGConfig
import EGLogging
import EGSimpleSettings
import EGWebAppExtensions
import EGWebSettingsScheme
import EGRequests
import EGRegDateScheme
import EGBadges

private let API_VERSION: String = "1"

private func buildApiUrl(_ endpoint: String) -> String {
    return "\(EG_CONFIG.apiUrl)/v\(API_VERSION)/\(endpoint)"
}

public let EG_API_AUTHORIZATION_HEADER = "Authorization"
public let EG_API_DEVICE_TOKEN_HEADER = "Device-Token"

private enum HTTPRequestError {
    case network
}

public enum EGAPIError {
    case generic(String? = nil)
}

public func getEGSettings(token: String) -> Signal<EGWebSettings, EGAPIError> {
    return Signal { subscriber in

        let url = URL(string: buildApiUrl("settings"))!
        let headers = [EG_API_AUTHORIZATION_HEADER: "Token \(token)"]
        let completed = Atomic<Bool>(value: false)
        
        var request = URLRequest(url: url)
        headers.forEach { key, value in
            request.addValue(value, forHTTPHeaderField: key)
        }
        
        let downloadSignal = requestsCustom(request: request).start(next: { data, urlResponse in
            let _ = completed.swap(true)
            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let settings = try decoder.decode(EGWebSettings.self, from: data)
                subscriber.putNext(settings)
                subscriber.putCompletion()
            } catch {
                subscriber.putError(.generic("Can't parse user settings: \(error). Response: \(String(data: data, encoding: .utf8) ?? "")"))
            }
        }, error: { error in
            subscriber.putError(.generic("Error requesting user settings: \(String(describing: error))"))
        })
        
        return ActionDisposable {
            if !completed.with({ $0 }) {
                downloadSignal.dispose()
            }
        }
    }
}



public func postSGSettings(token: String, data: [String:Any]) -> Signal<Void, EGAPIError> {
    return Signal { subscriber in

        let url = URL(string: buildApiUrl("settings"))!
        let headers = [EG_API_AUTHORIZATION_HEADER: "Token \(token)"]
        let completed = Atomic<Bool>(value: false)
        
        var request = URLRequest(url: url)
        headers.forEach { key, value in
            request.addValue(value, forHTTPHeaderField: key)
        }
        request.httpMethod = "POST"
        
        let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        let dataSignal = requestsCustom(request: request).start(next: { data, urlResponse in
            let _ = completed.swap(true)
            
            if let httpResponse = urlResponse as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200...299:
                    subscriber.putCompletion()
                default:
                    subscriber.putError(.generic("Can't update settings: \(httpResponse.statusCode). Response: \(String(data: data, encoding: .utf8) ?? "")"))
                }
            } else {
                subscriber.putError(.generic("Not an HTTP response: \(String(describing: urlResponse))"))
            }
        }, error: { error in
            subscriber.putError(.generic("Error updating settings: \(String(describing: error))"))
        })
        
        return ActionDisposable {
            if !completed.with({ $0 }) {
                dataSignal.dispose()
            }
        }
    }
}

public func getEGAPIRegDate(token: String, deviceToken: String, userId: Int64) -> Signal<RegDate, EGAPIError> {
    return Signal { subscriber in

        let url = URL(string: buildApiUrl("regdate/\(userId)"))!
        let headers = [
            EG_API_AUTHORIZATION_HEADER: "Token \(token)",
            EG_API_DEVICE_TOKEN_HEADER: deviceToken
        ]
        let completed = Atomic<Bool>(value: false)
        
        var request = URLRequest(url: url)
        headers.forEach { key, value in
            request.addValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = 10
        
        let downloadSignal = requestsCustom(request: request).start(next: { data, urlResponse in
            let _ = completed.swap(true)
            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let settings = try decoder.decode(RegDate.self, from: data)
                subscriber.putNext(settings)
                subscriber.putCompletion()
            } catch {
                subscriber.putError(.generic("Can't parse regDate: \(error). Response: \(String(data: data, encoding: .utf8) ?? "")"))
            }
        }, error: { error in
            subscriber.putError(.generic("Error requesting regDate: \(String(describing: error))"))
        })
        
        return ActionDisposable {
            if !completed.with({ $0 }) {
                downloadSignal.dispose()
            }
        }
    }
}


/// Fetch the full profiles list from the exteraGram API.
/// The result is used to populate `BadgesController.shared`.
/// Returns an empty array (no error) if the endpoint is not yet deployed (404).
/// Note: the endpoint is public — no Authorization header is sent.
public func getEGProfiles(token: String) -> Signal<[EGProfileDTO], EGAPIError> {
    return Signal { subscriber in
        let url = URL(string: buildApiUrl("profiles"))!
        let completed = Atomic<Bool>(value: false)

        let downloadSignal = requestsGet(url: url).start(next: { data, urlResponse in
            let _ = completed.swap(true)

            if let http = urlResponse as? HTTPURLResponse {
                // 404 = endpoint not deployed yet; treat as empty list, not an error.
                if http.statusCode == 404 {
                    subscriber.putNext([])
                    subscriber.putCompletion()
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    subscriber.putError(.generic("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")"))
                    return
                }
            }

            // JSON uses camelCase throughout — no key decoding strategy needed.
            if let profiles = try? JSONDecoder().decode([EGProfileDTO].self, from: data) {
                subscriber.putNext(profiles)
                subscriber.putCompletion()
            } else {
                subscriber.putError(.generic("Can't parse profiles. Response: \(String(data: data, encoding: .utf8) ?? "")"))
            }
        }, error: { error in
            subscriber.putError(.generic("Error requesting profiles: \(String(describing: error))"))
        })

        return ActionDisposable {
            if !completed.with({ $0 }) {
                downloadSignal.dispose()
            }
        }
    }
}


public func postEGReceipt(token: String, deviceToken: String, encodedReceiptData: Data) -> Signal<Void, EGAPIError> {
    return Signal { subscriber in

        let url = URL(string: buildApiUrl("validate"))!
        let headers = [
            EG_API_AUTHORIZATION_HEADER: "Token \(token)",
            EG_API_DEVICE_TOKEN_HEADER: deviceToken
        ]
        let completed = Atomic<Bool>(value: false)
        
        var request = URLRequest(url: url)
        headers.forEach { key, value in
            request.addValue(value, forHTTPHeaderField: key)
        }
        request.httpMethod = "POST"
        request.httpBody = encodedReceiptData
        
        let dataSignal = requestsCustom(request: request).start(next: { data, urlResponse in
            let _ = completed.swap(true)
            
            if let httpResponse = urlResponse as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200...299:
                    subscriber.putCompletion()
                default:
                    subscriber.putError(.generic("Error posting Receipt: \(httpResponse.statusCode). Response: \(String(data: data, encoding: .utf8) ?? "")"))
                }
            } else {
                subscriber.putError(.generic("Not an HTTP response: \(String(describing: urlResponse))"))
            }
        }, error: { error in
            subscriber.putError(.generic("Error posting Receipt: \(String(describing: error))"))
        })
        
        return ActionDisposable {
            if !completed.with({ $0 }) {
                dataSignal.dispose()
            }
        }
    }
}
