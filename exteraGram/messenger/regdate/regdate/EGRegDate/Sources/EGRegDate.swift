import Foundationimport SwiftSignalKitimport TelegramPresentationData
import loggingimport stringsimport apicoreimport AccountContextimport configcoreimport api
public enum RegDateError {
    case generic
}

public func getRegDate(context: AccountContext, peerId: Int64) -> Signal<RegDate?, NoError> {
    return Signal { subscriber in
        var tokensRequestSignal: Disposable? = nil
        var apiRequestSignal: Disposable? = nil
        if let regDateData = EGSimpleSettings.shared.regDateCache[String(peerId)], let regDate = try? JSONDecoder().decode(RegDate.self, from: regDateData), regDate.validUntil == 0 || regDate.validUntil > Int64(Date().timeIntervalSince1970) {
            subscriber.putNext(regDate)
            subscriber.putCompletion()
        } else if EGSimpleSettings.shared.showRegDate {
            tokensRequestSignal = combineLatest(getDeviceToken() |> mapError { error -> Void in EGLogger.shared.log("EGDeviceToken", "Error generating token: \(error)"); return Void() } , getEGApiToken(context: context) |> mapError { _ -> Void in return Void() }).start(next: { deviceToken, apiToken in
                apiRequestSignal = getEGAPIRegDate(token: apiToken, deviceToken: deviceToken, userId: peerId).start(next: { regDate in
                    if let data = try? JSONEncoder().encode(regDate) {
                        EGSimpleSettings.shared.regDateCache[String(peerId)] = data
                    }
                    subscriber.putNext(regDate)
                    subscriber.putCompletion()
                })
            })
        } else {
            subscriber.putNext(nil)
            subscriber.putCompletion()
        }

        return ActionDisposable {
            tokensRequestSignal?.dispose()
            apiRequestSignal?.dispose()
        }
    }
}
