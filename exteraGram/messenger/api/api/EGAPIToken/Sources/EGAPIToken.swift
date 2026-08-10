import Foundationimport SwiftSignalKitimport AccountContextimport TelegramCoreimport loggingimport configcoreimport webapp
private let tokenExpirationTime: TimeInterval = 30 * 60 // 30 minutes

private var tokenCache: [Int64: (token: String, expiration: Date)] = [:]

public enum EGAPITokenError {
    case generic(String? = nil)
}

public func getEGApiToken(context: AccountContext, botUsername: String = EG_CONFIG.botUsername) -> Signal<String, EGAPITokenError> {
    let userId = context.account.peerId.id._internalGetInt64Value()
    
    if let (token, expiration) = tokenCache[userId], Date() < expiration {
        // EGLogger.shared.log("EGAPI", "Using cached token. Expiring at: \(expiration)")
        return Signal { subscriber in
            subscriber.putNext(token)
            subscriber.putCompletion()
            return EmptyDisposable
        }
    }
    
    EGLogger.shared.log("EGAPI", "Requesting new token")
    // Workaround for Apple Review
    if context.account.testingEnvironment {
        return context.account.postbox.transaction { transaction -> String? in
            if let testUserPeer = transaction.getPeer(context.account.peerId) as? TelegramUser, let testPhone = testUserPeer.phone {
                return testPhone
            } else {
                return nil
            }
        }
        |> mapToSignalPromotingError { phone -> Signal<String, EGAPITokenError> in
            if let phone = phone {
                // https://core.telegram.org/api/auth#test-accounts
                if phone.starts(with: String(99966)) {
                    EGLogger.shared.log("EGAPI", "Using demo token")
                    tokenCache[userId] = (phone, Date().addingTimeInterval(tokenExpirationTime))
                    return .single(phone)
                } else {
                    return .fail(.generic("Non-demo phone number on test DC"))
                }
            } else {
                return .fail(.generic("Missing test account peer or it's number (how?)"))
            }
        }
    }
    
    return Signal { subscriber in
        let getSettingsURLSignal = getEGSettingsURL(context: context, botUsername: botUsername).start(next: { url in
            if let hashPart = url.components(separatedBy: "#").last {
                let parsedParams = urlParseHashParams(hashPart)
                if let token = parsedParams["tgWebAppData"], let token = token {
                    tokenCache[userId] = (token, Date().addingTimeInterval(tokenExpirationTime))
                    #if DEBUG
                    print("[EGAPI]", "API Token: \(token)")
                    #endif
                    subscriber.putNext(token)
                    subscriber.putCompletion()
                } else {
                    subscriber.putError(.generic("Invalid or missing token in response url! \(url)"))
                }
            } else {
                subscriber.putError(.generic("No hash part in URL \(url)"))
            }
        })
        
        return ActionDisposable {
            getSettingsURLSignal.dispose()
        }
    }
}

public func getEGSettingsURL(context: AccountContext, botUsername: String = EG_CONFIG.botUsername, url: String = EG_CONFIG.webappUrl, themeParams: [String: Any]? = nil) -> Signal<String, EGAPITokenError> {
    return Signal { subscriber in
        //      themeParams = generateWebAppThemeParams(
        //      context.sharedContext.currentPresentationData.with { $0 }.theme
        //      )
        var requestWebViewSignalDisposable: Disposable? = nil
        var requestUpdatePeerIsBlocked: Disposable? = nil
        let resolvePeerSignal = (
            context.engine.peers.resolvePeerByName(name: botUsername, referrer: nil)
            |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                guard case let .result(result) = result else {
                    return .complete()
                }
                return .single(result)
            }).start(next: { botPeer in
                if let botPeer = botPeer {
                    EGLogger.shared.log("EGAPI", "Botpeer found for \(botUsername)")
                    let requestWebViewSignal = context.engine.messages.requestWebView(peerId: botPeer.id, botId: botPeer.id, url: url, payload: nil, themeParams: themeParams, fromMenu: true, replyToMessageId: nil, threadId: nil)
                    
                    requestWebViewSignalDisposable = requestWebViewSignal.start(next: { webViewResult in
                        subscriber.putNext(webViewResult.url)
                        subscriber.putCompletion()
                    }, error: { e in
                        EGLogger.shared.log("EGAPI", "Webview request error, retrying with unblock")
                        // if e.errorDescription == "YOU_BLOCKED_USER" {
                        requestUpdatePeerIsBlocked = (context.engine.privacy.requestUpdatePeerIsBlocked(peerId: botPeer.id, isBlocked: false)
                          |> afterDisposed(
                            {
                                requestWebViewSignalDisposable?.dispose()
                                requestWebViewSignalDisposable = requestWebViewSignal.start(next: { webViewResult in
                                    EGLogger.shared.log("EGAPI", "Webview retry success \(webViewResult)")
                                    subscriber.putNext(webViewResult.url)
                                    subscriber.putCompletion()
                                }, error: { e in
                                    EGLogger.shared.log("EGAPI", "Webview retry failure \(e)")
                                    subscriber.putError(.generic("Webview retry failure \(e)"))
                                })
                            })).start()
                            // }
                    })
                    
                } else {
                    EGLogger.shared.log("EGAPI", "Botpeer not found for \(botUsername)")
                    subscriber.putError(.generic())
                }
            })
        
        return ActionDisposable {
            resolvePeerSignal.dispose()
            requestUpdatePeerIsBlocked?.dispose()
            requestWebViewSignalDisposable?.dispose()
        }
    }
}
