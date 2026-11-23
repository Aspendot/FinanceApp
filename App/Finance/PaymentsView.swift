import FinanceCore
import SwiftUI

struct PaymentsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedMonth: String?
    @State private var query = ""

    var body: some View {
        let months = model.data?.months ?? []
        let month = selectedMonth.flatMap { months.contains($0) ? $0 : nil } ?? months.last ?? ""
        NavigationStack {
            List {
                if let data = model.data {
                    let payments = data.paymentsByMonth[month] ?? []
                    let rows = query.isEmpty ? payments : payments.filter { row in
                        let item = row.value
                        return (item.merchant + " " + item.category + " " + item.source).localizedCaseInsensitiveContains(query)
                    }
                    let counted = rows.filter { data.layer(of: $0.value) != nil }.reduce(0) { $0 + $1.value.amount }
                    let pendingCount = rows.filter { $0.value.isPending }.count
                    Section {
                        Text("\(rows.count) payments · \(Money.yen(counted)) counted as spending"
                             + (pendingCount > 0 ? " · \(pendingCount) pending, from bank emails, not on a statement yet" : ""))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(rows) { row in
                            PaymentRow(item: row.value, counted: data.layer(of: row.value) != nil)
                        }
                    }
                } else {
                    Section { NoDataView() }
                }
            }
            .searchable(text: $query, prompt: "Shop, category or card")
            .navigationTitle(month.isEmpty ? "Payments" : DayText.month(month))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(months.reversed(), id: \.self) { m in
                            Button(DayText.month(m)) { selectedMonth = m }
                        }
                    } label: {
                        Label("Month", systemImage: "calendar")
                    }
                }
            }
            .refreshable { await model.syncGmail() }
        }
    }
}

struct PaymentRow: View {
    let item: BudgetItem
    let counted: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.merchant).font(.subheadline).lineLimit(1)
                    if item.isPending { PillTag("pending", color: .blue) }
                    if !counted { PillTag("not spending") }
                }
                Text("\(DayText.short(item.date)) · \(item.category) · \(item.source)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Money.payment(item.amount))
                .font(.subheadline).monospacedDigit()
                .foregroundStyle(item.amount < 0 ? Color.green : Color.primary)
        }
        .padding(.vertical, 2)
    }
}
