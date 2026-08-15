import Foundation

enum LauncherPhase: Equatable {
    case starting
    case ready(URL)
    case stopped
    case busy(String)
    case runtimeMissing(String)
    case failed(String)

    var title: String {
        switch self {
        case .starting:
            return "Starting DeepSeek Harness"
        case .ready:
            return "DeepSeek Harness Running"
        case .stopped:
            return "DeepSeek Harness Stopped"
        case .busy(let operation):
            return operation
        case .runtimeMissing:
            return "DeepSeek Harness Runtime Not Found"
        case .failed:
            return "DeepSeek Harness Failed to Start"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum PluginRuntimeState: String, Equatable {
    case running = "Running"
    case stopped = "Stopped"
    case starting = "Starting"
    case stopping = "Stopping"
    case error = "Error"
}

enum RuntimeUpdateState: Equatable {
    case idle
    case checking
    case available(String)
    case downloaded(String)
    case upToDate
    case failed(String)
}

struct DeepSeekBalanceInfo: Codable, Equatable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String
    let toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }

    init(
        currency: String,
        totalBalance: String,
        grantedBalance: String,
        toppedUpBalance: String
    ) {
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currency = try container.decode(String.self, forKey: .currency)
        totalBalance = try container.decodeLossyString(forKey: .totalBalance)
        grantedBalance = try container.decodeLossyString(forKey: .grantedBalance)
        toppedUpBalance = try container.decodeLossyString(forKey: .toppedUpBalance)
    }
}

struct DeepSeekBalanceResponse: Codable, Equatable {
    let isAvailable: Bool
    let balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

enum DeepSeekBalanceTone: Equatable {
    case unknown
    case healthy
    case warning
    case critical

    init(balanceInfos: [DeepSeekBalanceInfo]) {
        guard let cny = balanceInfos.first(where: { $0.currency.uppercased() == "CNY" }),
              let amount = Decimal(string: cny.totalBalance, locale: Locale(identifier: "en_US_POSIX")) else {
            self = .unknown
            return
        }

        if amount >= Decimal(100) {
            self = .healthy
        } else if amount >= Decimal(50) {
            self = .warning
        } else {
            self = .critical
        }
    }
}

enum DeepSeekBalanceState: Equatable {
    case notConfigured
    case loading
    case available([DeepSeekBalanceInfo])
    case failed(String)
}

private extension KeyedDecodingContainer {
    func decodeLossyString(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }
        if let number = try? decode(Double.self, forKey: key) {
            return String(number)
        }
        return "-"
    }
}

struct HarnessPlugin: Identifiable, Equatable {
    let id: String
    let version: String
    let bundleRowIDs: [String]
    let isDisabled: Bool

    var name: String { id }
    var state: PluginRuntimeState { isDisabled ? .stopped : .running }
}
