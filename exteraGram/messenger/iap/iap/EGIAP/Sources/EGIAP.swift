import StoreKitimport configcoreimport loggingimport AppBundleimport Combine
private final class CurrencyFormatterEntry {
    public let symbol: String
    public let thousandsSeparator: String
    public let decimalSeparator: String
    public let symbolOnLeft: Bool
    public let spaceBetweenAmountAndSymbol: Bool
    public let decimalDigits: Int
    
    public init(symbol: String, thousandsSeparator: String, decimalSeparator: String, symbolOnLeft: Bool, spaceBetweenAmountAndSymbol: Bool, decimalDigits: Int) {
        self.symbol = symbol
        self.thousandsSeparator = thousandsSeparator
        self.decimalSeparator = decimalSeparator
        self.symbolOnLeft = symbolOnLeft
        self.spaceBetweenAmountAndSymbol = spaceBetweenAmountAndSymbol
        self.decimalDigits = decimalDigits
    }
}

private func getCurrencyExp(currency: String) -> Int {
    switch currency {
    case "CLF":
        return 4
    case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND":
        return 3
    case "BIF", "BYR", "CLP", "CVE", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF":
        return 0
    case "MRO":
        return 1
    default:
        return 2
    }
}

private func loadCurrencyFormatterEntries() -> [String: CurrencyFormatterEntry] {
    guard let filePath = getAppBundle().path(forResource: "currencies", ofType: "json") else {
        return [:]
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
        return [:]
    }
    
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []), let dict = object as? [String: AnyObject] else {
        return [:]
    }
    
    var result: [String: CurrencyFormatterEntry] = [:]
    
    for (code, contents) in dict {
        if let contentsDict = contents as? [String: AnyObject] {
            let entry = CurrencyFormatterEntry(
                symbol: contentsDict["symbol"] as! String,
                thousandsSeparator: contentsDict["thousandsSeparator"] as! String,
                decimalSeparator: contentsDict["decimalSeparator"] as! String,
                symbolOnLeft: (contentsDict["symbolOnLeft"] as! NSNumber).boolValue,
                spaceBetweenAmountAndSymbol: (contentsDict["spaceBetweenAmountAndSymbol"] as! NSNumber).boolValue,
                decimalDigits: getCurrencyExp(currency: code.uppercased())
            )
            result[code] = entry
            result[code.lowercased()] = entry
        }
    }
    
    return result
}

private let currencyFormatterEntries = loadCurrencyFormatterEntries()

private func fractionalValueToCurrencyAmount(value: Double, currency: String) -> Int64? {
    guard let entry = currencyFormatterEntries[currency] ?? currencyFormatterEntries["USD"] else {
        return nil
    }
    var factor: Double = 1.0
    for _ in 0 ..< entry.decimalDigits {
        factor *= 10.0
    }
    if value > Double(Int64.max) / factor {
        return nil
    } else {
        return Int64(value * factor)
    }
}


public extension Notification.Name {
    static let EGIAPHelperPurchaseNotification = Notification.Name("EGIAPPurchaseNotification")
    static let EGIAPHelperErrorNotification = Notification.Name("EGIAPErrorNotification")
    static let EGIAPHelperProductsUpdatedNotification = Notification.Name("EGIAPProductsUpdatedNotification")
    static let EGIAPHelperValidationErrorNotification = Notification.Name("EGIAPValidationErrorNotification")
}

public final class EGIAPManager: NSObject {
    private var productRequest: SKProductsRequest?
    private var productsRequestCompletion: (([SKProduct]) -> Void)?
    private var purchaseCompletion: ((Bool, Error?) -> Void)?
    
    public private(set) var availableProducts: [EGProduct] = []
    private var finishedSuccessfulTransactions = Set<String>()
    private var onRestoreCompletion: (() -> Void)?
    
    public final class EGProduct: Equatable {
        private lazy var numberFormatter: NumberFormatter = {
            let numberFormatter = NumberFormatter()
            numberFormatter.numberStyle = .currency
            numberFormatter.locale = self.skProduct.priceLocale
            return numberFormatter
        }()
        
        public let skProduct: SKProduct
        
        init(skProduct: SKProduct) {
            self.skProduct = skProduct
        }
        
        public var id: String {
            return self.skProduct.productIdentifier
        }
        
        public var isSubscription: Bool {
            if #available(iOS 12.0, *) {
                return self.skProduct.subscriptionGroupIdentifier != nil
            } else {
                return self.skProduct.subscriptionPeriod != nil
            }
        }
        
        public var price: String {
            return self.numberFormatter.string(from: self.skProduct.price) ?? ""
        }
        
        public func pricePerMonth(_ monthsCount: Int) -> String {
            let price = self.skProduct.price.dividing(by: NSDecimalNumber(value: monthsCount)).round(2)
            return self.numberFormatter.string(from: price) ?? ""
        }
        
        public func defaultPrice(_ value: NSDecimalNumber, monthsCount: Int) -> String {
            let price = value.multiplying(by: NSDecimalNumber(value: monthsCount)).round(2)
            let prettierPrice = price
                .multiplying(by: NSDecimalNumber(value: 2))
                .rounding(accordingToBehavior:
                    NSDecimalNumberHandler(
                        roundingMode: .up,
                        scale: Int16(0),
                        raiseOnExactness: false,
                        raiseOnOverflow: false,
                        raiseOnUnderflow: false,
                        raiseOnDivideByZero: false
                    )
                )
                .dividing(by: NSDecimalNumber(value: 2))
                .subtracting(NSDecimalNumber(value: 0.01))
            return self.numberFormatter.string(from: prettierPrice) ?? ""
        }
        
        public func multipliedPrice(count: Int) -> String {
            let price = self.skProduct.price.multiplying(by: NSDecimalNumber(value: count)).round(2)
            let prettierPrice = price
                .multiplying(by: NSDecimalNumber(value: 2))
                .rounding(accordingToBehavior:
                    NSDecimalNumberHandler(
                        roundingMode: .up,
                        scale: Int16(0),
                        raiseOnExactness: false,
                        raiseOnOverflow: false,
                        raiseOnUnderflow: false,
                        raiseOnDivideByZero: false
                    )
                )
                .dividing(by: NSDecimalNumber(value: 2))
                .subtracting(NSDecimalNumber(value: 0.01))
            return self.numberFormatter.string(from: prettierPrice) ?? ""
        }
        
        public var priceValue: NSDecimalNumber {
            return self.skProduct.price
        }
        
        public var priceCurrencyAndAmount: (currency: String, amount: Int64) {
            if let currencyCode = self.numberFormatter.currencyCode,
                let amount = fractionalValueToCurrencyAmount(value: self.priceValue.doubleValue, currency: currencyCode) {
                return (currencyCode, amount)
            } else {
                return ("", 0)
            }
        }
        
        public static func ==(lhs: EGProduct, rhs: EGProduct) -> Bool {
            if lhs.id != rhs.id {
                return false
            }
            if lhs.isSubscription != rhs.isSubscription {
                return false
            }
            if lhs.priceValue != rhs.priceValue {
                return false
            }
            return true
        }
        
    }
    
    public init(foo: Bool = false) { // I don't want to override init, idk why
        super.init()

        SKPaymentQueue.default().add(self)

        #if DEBUG && false
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            self.requestProducts()
        }
        #else
        self.requestProducts()
        #endif
    }
    
    deinit {
        SKPaymentQueue.default().remove(self)
    }
    
    public var canMakePayments: Bool {
        return SKPaymentQueue.canMakePayments()
    }
    
    public func buyProduct(_ product: SKProduct) {
        EGLogger.shared.log("EGIAP", "Buying \(product.productIdentifier)...")
        let payment = SKPayment(product: product)
        SKPaymentQueue.default().add(payment)
    }
    
    private func requestProducts() {
        EGLogger.shared.log("EGIAP", "Requesting products for 0 ids...")
        let productRequest = SKProductsRequest(productIdentifiers: Set<String>())
        
        productRequest.delegate = self
        productRequest.start()
        
        self.productRequest = productRequest
    }
    
    public func restorePurchases(completion: @escaping () -> Void) {
        EGLogger.shared.log("EGIAP", "Restoring purchases...")
        self.onRestoreCompletion = completion

        let paymentQueue = SKPaymentQueue.default()
        paymentQueue.restoreCompletedTransactions()
    }

}

extension EGIAPManager: SKProductsRequestDelegate {
    public func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        self.productRequest = nil
        
        DispatchQueue.main.async {
            let products = response.products
            EGLogger.shared.log("EGIAP", "Received products (\(products.count)): \(products.map({ $0.productIdentifier }).joined(separator: ", "))")
            let currentlyAvailableProducts = self.availableProducts
            self.availableProducts = products.map({ EGProduct(skProduct: $0) })
            if currentlyAvailableProducts != self.availableProducts {
                NotificationCenter.default.post(name: .EGIAPHelperProductsUpdatedNotification, object: nil)
            }
        }
    }
    
    public func request(_ request: SKRequest, didFailWithError error: Error) {
        EGLogger.shared.log("EGIAP", "Failed to load list of products. Error \(error.localizedDescription)")
        self.productRequest = nil
    }
}

extension EGIAPManager: SKPaymentTransactionObserver {
    public func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        EGLogger.shared.log("EGIAP", "paymentQueue transactions \(transactions.count)")
        var purchaceTransactions: [SKPaymentTransaction] = []
        for transaction in transactions {
            EGLogger.shared.log("EGIAP", "Transaction \(transaction.transactionIdentifier ?? "nil") state for product \(transaction.payment.productIdentifier): \(transaction.transactionState.description)")
            switch transaction.transactionState {
                case .purchased, .restored:
                    purchaceTransactions.append(transaction)
                    break
                case .purchasing, .deferred:
                    // Ignoring
                    break
                case .failed:
                    var localizedError: String = ""
                    if let transactionError = transaction.error as NSError?,
                        let localizedDescription = transaction.error?.localizedDescription,
                        transactionError.code != SKError.paymentCancelled.rawValue {
                        localizedError = localizedDescription
                        EGLogger.shared.log("EGIAP", "Transaction Error [\(transaction.transactionIdentifier ?? "nil")]: \(localizedDescription)")
                    }
                    EGLogger.shared.log("EGIAP", "Sending EGIAPHelperErrorNotification for \(transaction.transactionIdentifier ?? "nil")")
                    NotificationCenter.default.post(name: .EGIAPHelperErrorNotification, object: transaction, userInfo: ["localizedError": localizedError])
                default:
                    EGLogger.shared.log("EGIAP", "Unknown transaction \(transaction.transactionIdentifier ?? "nil") state \(transaction.transactionState). Finishing transaction.")
                    SKPaymentQueue.default().finishTransaction(transaction)
            }
        }
        
        if !purchaceTransactions.isEmpty {
            EGLogger.shared.log("EGIAP", "Sending EGIAPHelperPurchaseNotification for \(purchaceTransactions.map({ $0.transactionIdentifier ?? "nil" }).joined(separator: ", "))")
            NotificationCenter.default.post(name: .EGIAPHelperPurchaseNotification, object: purchaceTransactions)
        }
    }
    
    public func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        EGLogger.shared.log("EGIAP", "Transactions restored")
        
        if let onRestoreCompletion = self.onRestoreCompletion {
            self.onRestoreCompletion = nil
            onRestoreCompletion()
        }
    }

}

private extension NSDecimalNumber {
    func round(_ decimals: Int) -> NSDecimalNumber {
        return self.rounding(accordingToBehavior:
                            NSDecimalNumberHandler(roundingMode: .down,
                                   scale: Int16(decimals),
                                   raiseOnExactness: false,
                                   raiseOnOverflow: false,
                                   raiseOnUnderflow: false,
                                   raiseOnDivideByZero: false))
    }
    
    func prettyPrice() -> NSDecimalNumber {
        return self.multiplying(by: NSDecimalNumber(value: 2))
            .rounding(accordingToBehavior:
                NSDecimalNumberHandler(
                    roundingMode: .plain,
                    scale: Int16(0),
                    raiseOnExactness: false,
                    raiseOnOverflow: false,
                    raiseOnUnderflow: false,
                    raiseOnDivideByZero: false
                )
            )
            .dividing(by: NSDecimalNumber(value: 2))
            .subtracting(NSDecimalNumber(value: 0.01))
    }
}


public func getPurchaceReceiptData() -> Data? {
    var receiptData: Data?
    if let appStoreReceiptURL = Bundle.main.appStoreReceiptURL, FileManager.default.fileExists(atPath: appStoreReceiptURL.path) {
        do {
            receiptData = try Data(contentsOf: appStoreReceiptURL, options: .alwaysMapped)
        } catch {
            EGLogger.shared.log("EGIAP", "Couldn't read receipt data with error: \(error.localizedDescription)")
        }
    } else {
        EGLogger.shared.log("EGIAP", "Couldn't find receipt path")
    }
    return receiptData
}


extension SKPaymentTransactionState {
    var description: String {
        switch self {
        case .purchasing:
            return "Purchasing"
        case .purchased:
            return "Purchased"
        case .failed:
            return "Failed"
        case .restored:
            return "Restored"
        case .deferred:
            return "Deferred"
        @unknown default:
            return "Unknown"
        }
    }
}

