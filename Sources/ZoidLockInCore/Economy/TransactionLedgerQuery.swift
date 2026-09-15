import Foundation

/// Dashboard audit filter for the append-only wallet ledger.
public enum LedgerAuditKind: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case all
    case mint
    case debit
    case emergency
    case habit
    case meeting
    case surplus

    public var caption: String {
        rawValue.uppercased()
    }

    public func matches(_ transaction: WalletTransaction) -> Bool {
        switch self {
        case .all:
            return true
        case .mint:
            return transaction.transactionType == .mint
        case .debit:
            switch transaction.transactionType {
            case .spend, .refund, .reset:
                return true
            case .mint, .earnedMeeting, .earnedHabit, .penalty, .surplusTransfer:
                return false
            }
        case .emergency:
            return transaction.transactionType == .penalty
                && !(transaction.referenceID?.hasPrefix("deficit:") ?? false)
        case .habit:
            return transaction.transactionType == .earnedHabit
        case .meeting:
            return transaction.transactionType == .earnedMeeting
        case .surplus:
            return transaction.transactionType == .surplusTransfer
        }
    }
}

public struct TransactionLedgerPage: Sendable, Equatable {
    public var items: [WalletTransaction]
    public var page: Int
    public var pageSize: Int
    public var totalItems: Int
    public var totalPages: Int
    public var filter: LedgerAuditKind
    public var search: String

    public init(
        items: [WalletTransaction],
        page: Int,
        pageSize: Int,
        totalItems: Int,
        totalPages: Int,
        filter: LedgerAuditKind,
        search: String
    ) {
        self.items = items
        self.page = page
        self.pageSize = pageSize
        self.totalItems = totalItems
        self.totalPages = totalPages
        self.filter = filter
        self.search = search
    }

    public var hasPrevious: Bool { page > 1 }
    public var hasNext: Bool { page < totalPages }

    public static let empty = TransactionLedgerPage(
        items: [],
        page: 1,
        pageSize: 10,
        totalItems: 0,
        totalPages: 1,
        filter: .all,
        search: ""
    )
}

/// Pure pagination, type filter, and text search over wallet rows.
public enum TransactionLedgerQuery: Sendable {
    public static let defaultPageSize = 10
    public static let pageSizeOptions = [10, 25, 50]

    public static func page(
        from transactions: [WalletTransaction],
        filter: LedgerAuditKind = .all,
        search: String = "",
        page: Int = 1,
        pageSize: Int = defaultPageSize
    ) -> TransactionLedgerPage {
        let size = max(1, pageSize)
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = transactions.filter { transaction in
            guard filter.matches(transaction) else { return false }
            guard !needle.isEmpty else { return true }
            return matchesSearch(transaction, needle: needle)
        }
        .sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }

        let total = filtered.count
        let totalPages = max(1, Int(ceil(Double(total) / Double(size))))
        let clampedPage = min(max(1, page), totalPages)
        let start = (clampedPage - 1) * size
        let items: [WalletTransaction]
        if start >= total {
            items = []
        } else {
            let end = min(start + size, total)
            items = Array(filtered[start..<end])
        }

        return TransactionLedgerPage(
            items: items,
            page: clampedPage,
            pageSize: size,
            totalItems: total,
            totalPages: totalPages,
            filter: filter,
            search: needle
        )
    }

    private static func matchesSearch(_ transaction: WalletTransaction, needle: String) -> Bool {
        let haystacks = [
            transaction.description,
            transaction.transactionType.rawValue,
            transaction.referenceID ?? "",
            CreditMath.displayString(transaction.amount),
            transaction.id.uuidString,
        ]
        return haystacks.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}
