import Foundationimport loggingimport configcoreimport AccountContextimport TelegramCore

public func updateEGGHSettingsInteractivelly(context: AccountContext) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let locale = presentationData.strings.baseLanguageCode
    let _ = Task {
        do {
            let settings = try await fetchSGGHSettings(locale: locale)
            let _ = await (context.account.postbox.transaction { transaction in
                updateAppConfiguration(transaction: transaction, { configuration -> AppConfiguration in
                    var configuration = configuration
                    configuration.egGHSettings = settings
                    return configuration
                })
            }).task()
        } catch {
            return
        }

    }
}


let maxRetries: Int = 3

enum EGGHFetchError: Error {
    case invalidURL
    case notFound
    case fetchFailed(statusCode: Int)
    case decodingFailed
}

func fetchSGGHSettings(locale: String) async throws -> EGGHSettings {
    let baseURL = "https://raw.githubusercontent.com/exteraGram/settings/refs/heads/main"
    var candidates: [String] = []
    if let buildNumber = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
        if locale != "en" {
            candidates.append("\(buildNumber)_\(locale).json")
        }
        candidates.append("\(buildNumber).json")
    }
    if locale != "en" {
        candidates.append("latest_\(locale).json")
    }
    candidates.append("latest.json")

    var lastError: Error?
    for candidate in candidates {
        let urlString = "\(baseURL)/\(candidate)"
        guard let url = URL(string: urlString) else {
            EGLogger.shared.log("EGGHSettings", "[0] Fetch failed for \(candidate). Invalid URL: \(urlString)")
            continue
        }

        attemptsOuter: for attempt in 1...maxRetries {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse else {
                    EGLogger.shared.log("EGGHSettings", "[\(attempt)] Fetch failed for \(candidate). Invalid response type: \(response)")
                    throw EGGHFetchError.fetchFailed(statusCode: -1)
                }

                switch httpResponse.statusCode {
                case 200:
                    do {
                        let jsonDecoder = JSONDecoder()
                        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
                        let settings = try jsonDecoder.decode(EGGHSettings.self, from: data)
                        EGLogger.shared.log("EGGHSettings", "[\(attempt)] Fetched \(candidate): \(settings)")
                        return settings
                    } catch {
                        EGLogger.shared.log("EGGHSettings", "[\(attempt)] Failed to decode \(candidate): \(error)")
                        throw EGGHFetchError.decodingFailed
                    }
                case 404:
                    EGLogger.shared.log("EGGHSettings", "[\(attempt)] Not found \(candidate) on the remote.")
                    break attemptsOuter
                default:
                    EGLogger.shared.log("EGGHSettings", "[\(attempt)] Fetch failed for \(candidate), status code: \(httpResponse.statusCode)")
                    throw EGGHFetchError.fetchFailed(statusCode: httpResponse.statusCode)
                }
            } catch {
                lastError = error
                if attempt == maxRetries {
                    break
                }
                try await Task.sleep(nanoseconds: UInt64(attempt * 2 * 1_000_000_000))
            }
        }
    }

    EGLogger.shared.log("EGGHSettings", "All attempts failed. Last error: \(String(describing: lastError))")
    throw EGGHFetchError.fetchFailed(statusCode: -1)
}
