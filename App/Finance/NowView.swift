import FinanceCore
import SwiftUI

struct NowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let data = model.data {
                    if let payday = data.payday {
                        Section {
                            PaydayCard(payday: payday, spent: data.spentSincePayday,
                                       lastPayday: data.lastPayday, pendingCount: data.pendingSincePayday)
                        }
                    } else {
                        Section { Text("No upcoming payday in the data file.") }
                    }
                    Section("Coming up") {
                        ForEach(data.comingUp, id: \.date) { group in
                            ComingUpDay(group: group)
                        }
                    }
                } else {
                    Section { NoDataView() }
                }
            }
            .navigationTitle("Now")
            .refreshable { await model.syncGmail() }
        }
    }
}

struct PaydayCard: View {
    let payday: PaydayView
    let spent: Int?
    let lastPayday: String?
    let pendingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Until payday").font(.headline)
            Text("To \(DayText.long(payday.next.date)): \(payday.daysToPayday) days from today")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(Money.yen(payday.left))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("left for everything else (food, transport, going out) after the bills in Coming up are paid")
                .font(.footnote).foregroundStyle(.secondary)
            SplitBar(bills: payday.outSum, left: payday.left, borrowed: payday.borrowedSum)
                .padding(.vertical, 4)
            LedgerRow(title: "Money in",
                      detail: payday.ins.map { "\($0.item) \(Money.yen(-$0.amount))" }.joined(separator: " · "),
                      value: Money.signed(payday.inSum))
            if !payday.outs.isEmpty {
                LedgerRow(title: "Bills until payday",
                          detail: "\(payday.outs.count) payments, \(DayText.short(payday.outs.first!.date)) to \(DayText.short(payday.outs.last!.date))",
                          value: Money.signed(-payday.outSum))
            }
            LedgerRow(title: "Left for everything else", detail: nil, value: Money.yen(payday.left), total: true)
            if payday.borrowedSum > 0 {
                LedgerRow(title: "Borrowing you plan",
                          detail: payday.borrowed.map { "\($0.item.split(separator: ":").first ?? "") \(Money.yen(-$0.amount))" }.joined(separator: " · "),
                          value: Money.signed(payday.borrowedSum))
                LedgerRow(title: "Left if you borrow it", detail: nil, value: Money.yen(payday.leftIfBorrowed), total: true)
            }
            if let spent, let lastPayday {
                LedgerRow(title: "Spent since payday",
                          detail: "Since \(DayText.short(lastPayday)), from statements and bank emails"
                            + (pendingCount > 0 ? ", including \(pendingCount) pending" : ""),
                          value: Money.yen(spent))
            }
        }
        .padding(.vertical, 6)
    }
}

struct SplitBar: View {
    let bills: Int
    let left: Int
    let borrowed: Int

    var body: some View {
        let parts: [(Int, Color, String)] = [(bills, Color.secondary.opacity(0.45), "Bills"), (left, Color.green, "Left"), (borrowed, Color.teal.opacity(0.6), "Borrowed")]
            .filter { $0.0 > 0 }
        let total = max(1, parts.map(\.0).reduce(0, +))
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.2) { part in
                        Capsule().fill(part.1)
                            .frame(width: max(4, geo.size.width * CGFloat(part.0) / CGFloat(total) - 2))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                ForEach(parts, id: \.2) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.1).frame(width: 8, height: 8)
                        Text("\(part.2) \(Money.yen(part.0))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct LedgerRow: View {
    let title: String
    let detail: String?
    let value: String
    var total = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(total ? .subheadline.weight(.semibold) : .subheadline)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(value).font(total ? .subheadline.weight(.semibold) : .subheadline).monospacedDigit()
        }
        .padding(.top, total ? 4 : 0)
    }
}

struct ComingUpDay: View {
    let group: ComingUpGroup

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(DayText.weekday(group.date)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(DayText.dayOfMonth(group.date)).font(.title3.weight(.semibold)).monospacedDigit()
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 8) {
                if group.isToday {
                    Text("TODAY").font(.caption2.weight(.bold)).foregroundStyle(.blue)
                }
                ForEach(NumberedRow.make(from: group.entries)) { row in
                    entryRow(row.value)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(group.isPast && !group.isToday ? 0.55 : 1)
        .listRowBackground(group.hasPayday ? Color.green.opacity(0.10) : nil)
    }

    @ViewBuilder
    private func entryRow(_ e: TimelineEntry) -> some View {
        let moneyIn = e.amount < 0 && e.borrowed != true
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.item).font(.subheadline)
                    if e.payday == true { PillTag("payday", color: .green) }
                    if e.done == true { PillTag("received") }
                    if e.borrowed == true { PillTag("borrowed") }
                    if e.estimate == true { PillTag("estimate") }
                }
                if let note = e.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if e.amount != 0 {
                Text(e.amount < 0 ? "+¥" + e.amount.magnitude.formatted() : "¥" + e.amount.formatted())
                    .font(.subheadline).monospacedDigit()
                    .foregroundStyle(moneyIn ? Color.green : Color.primary)
            }
        }
    }
}

struct PillTag: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.6), lineWidth: 1))
    }
}
