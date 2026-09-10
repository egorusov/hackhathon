import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    private let cashbackCategories = [
        CashbackCategory(title: "Все\nпокупки", percent: "1%", color: Color(hex: "8B6BE8"), symbol: "bag.fill"),
        CashbackCategory(title: "Дом\nи ремонт", percent: "5%", color: Color(hex: "58C86D"), symbol: "paintbrush.fill"),
        CashbackCategory(title: "Рестораны", percent: "5%", color: Color(hex: "FF862A"), symbol: "fork.knife"),
        CashbackCategory(title: "Цветы", percent: "10%", color: Color(hex: "ED4CB9"), symbol: "leaf.fill"),
        CashbackCategory(title: "Такси", percent: "3%", color: Color(hex: "F4C928"), symbol: "car.fill")
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    backButton
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    BankCardCarousel()
                        .padding(.top, 33)

                    accountSummary
                        .padding(.top, 45)

                    actionButtons
                        .padding(.top, 40)

                    cashbackCard
                        .padding(.top, 28)

                    operationsCard
                        .padding(.top, 22)

                    detailsCard
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomNavigation
        }
        .preferredColorScheme(.dark)
    }

    private var backButton: some View {
        HStack {
            Button(action: {}) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.055))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    private var accountSummary: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Text("Счет Black")
                    .font(.system(size: 16, weight: .semibold))

                Image(systemName: "pencil")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Circle())
            }

            Text("18 123,45 ₽")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .tracking(-0.5)
        }
        .foregroundStyle(.white)
    }

    private var actionButtons: some View {
        HStack(alignment: .top, spacing: 38) {
            ActionButton(title: "Пополнить", symbol: "plus")
            ActionButton(title: "Оплатить", symbol: "viewfinder")
            ActionButton(title: "Перевести", symbol: "arrow.right")
        }
    }

    private var cashbackCard: some View {
        VStack(spacing: 15) {
            HStack {
                Text("Кэшбэк в январе")
                    .font(.system(size: 20, weight: .bold))

                Spacer()

                Button("Все", action: {})
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color(hex: "4AA3FF"))
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 13) {
                    ForEach(cashbackCategories) { category in
                        CashbackItem(category: category)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 16)
        .frame(height: 170, alignment: .top)
        .background(Color(hex: "1C1C1E"))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var operationsCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Операции")
                    .font(.system(size: 20, weight: .bold))

                Text("Траты в марте 26 257 ₽")
                    .font(.system(size: 15.5, weight: .regular))
                    .foregroundStyle(Color(hex: "8C8C93"))
            }

            Spacer(minLength: 4)

            HStack(spacing: 7) {
                MiniOperation(symbol: "bag.fill", color: Color(hex: "0A84FF"))
                MiniOperation(symbol: "paintbrush.fill", color: Color(hex: "60D394"))
                MiniOperation(symbol: "fork.knife", color: Color(hex: "FF67B0"))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 79)
        .background(Color(hex: "1C1C1E"))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Детали")
                .font(.system(size: 20, weight: .bold))
                .padding(.bottom, 15)

            DetailButton(title: "Реквизиты счета")
            DetailButton(title: "Тариф")
            DetailButton(title: "Выписка по счету")
            DetailButton(title: "Заказать справку")
            DetailButton(title: "Заблокировать карту", isDestructive: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 11)
        .background(Color(hex: "1C1C1E"))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var bottomNavigation: some View {
        HStack(spacing: 0) {
            TabButton(title: "Главная", symbol: "diamond.fill", index: 0, selectedTab: $selectedTab)
            TabButton(title: "Платежи", symbol: "circle.fill", index: 1, selectedTab: $selectedTab)
            TabButton(title: "Город", symbol: "triangle.fill", index: 2, selectedTab: $selectedTab)
            TabButton(title: "Чат", symbol: "seal.fill", index: 3, selectedTab: $selectedTab)
            TabButton(title: "Витрина", symbol: "square.fill", index: 4, selectedTab: $selectedTab)
        }
        .padding(.horizontal, 7)
        .frame(height: 62)
        .background(
            LinearGradient(
                colors: [Color(hex: "151515").opacity(0.98), Color(hex: "090909").opacity(0.98)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 27)
        .padding(.top, 6)
        .padding(.bottom, 7)
        .background(Color.black)
    }
}

private struct BankCardCarousel: View {
    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 32) {
                    BankCardView()
                    BankCardView(isSecondary: true)
                }
                .padding(.leading, max(16, (proxy.size.width - 242) / 2))
                .padding(.trailing, 16)
            }
        }
        .frame(height: 153)
    }
}

private struct BankCardView: View {
    var isSecondary = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isSecondary
                            ? [Color(hex: "242424"), Color(hex: "101010")]
                            : [Color(hex: "494949"), Color(hex: "101010"), Color(hex: "090909")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if !isSecondary {
                Path { path in
                    path.move(to: CGPoint(x: 95, y: -3))
                    path.addCurve(
                        to: CGPoint(x: 151, y: 76),
                        control1: CGPoint(x: 118, y: 8),
                        control2: CGPoint(x: 134, y: 48)
                    )
                    path.addCurve(
                        to: CGPoint(x: 95, y: 156),
                        control1: CGPoint(x: 133, y: 109),
                        control2: CGPoint(x: 119, y: 145)
                    )
                }
                .stroke(Color.white.opacity(0.62), style: StrokeStyle(lineWidth: 4, lineCap: .round))

                CardChip()
                    .position(x: 43, y: 64)

                Text("•1234")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Capsule())
                    .position(x: 40, y: 126)

                VStack(alignment: .trailing, spacing: -2) {
                    Text("MIR")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .italic()
                    Text("SUPREME")
                        .font(.system(size: 5.2, weight: .black))
                        .tracking(0.8)
                    Text("BLACK")
                        .font(.system(size: 8, weight: .black))
                }
                .foregroundStyle(Color.white.opacity(0.67))
                .position(x: 205, y: 127)

                ShieldMark()
                    .position(x: 218, y: 23)
            }
        }
        .frame(width: 242, height: 153)
        .overlay(
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
    }
}

private struct CardChip: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "D7D7D7"), Color(hex: "8E8E8E")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Path { path in
                path.move(to: CGPoint(x: 0, y: 10))
                path.addLine(to: CGPoint(x: 32, y: 10))
                path.move(to: CGPoint(x: 0, y: 19))
                path.addLine(to: CGPoint(x: 32, y: 19))
                path.move(to: CGPoint(x: 10, y: 0))
                path.addCurve(to: CGPoint(x: 10, y: 29), control1: CGPoint(x: 5, y: 9), control2: CGPoint(x: 16, y: 20))
                path.move(to: CGPoint(x: 22, y: 0))
                path.addCurve(to: CGPoint(x: 22, y: 29), control1: CGPoint(x: 27, y: 9), control2: CGPoint(x: 16, y: 20))
            }
            .stroke(Color.black.opacity(0.28), lineWidth: 0.8)
        }
        .frame(width: 32, height: 24)
    }
}

private struct ShieldMark: View {
    var body: some View {
        ZStack {
            ShieldShape()
                .fill(Color.white.opacity(0.82))

            Text("T")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .offset(y: -1)
        }
        .frame(width: 20, height: 21)
    }
}

private struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + 2))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 2))
        path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.midY + 3))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX - 3, y: rect.maxY - 3),
            control2: CGPoint(x: rect.midX + 4, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + 1, y: rect.midY + 3),
            control1: CGPoint(x: rect.midX - 4, y: rect.maxY),
            control2: CGPoint(x: rect.minX + 3, y: rect.maxY - 3)
        )
        path.closeSubpath()
        return path
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String

    var body: some View {
        Button(action: {}) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.white)
                    .background(Color(hex: "1B1B1D"))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))

                Text(title)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.88))
            }
            .frame(width: 60)
        }
        .buttonStyle(.plain)
    }
}

private struct CashbackCategory: Identifiable {
    let id = UUID()
    let title: String
    let percent: String
    let color: Color
    let symbol: String
}

private struct CashbackItem: View {
    let category: CashbackCategory

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(category.color)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: category.symbol)
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.9))
                    )

                Text(category.percent)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Color(hex: "F6DD18"))
                    .clipShape(Capsule())
                    .offset(x: 2, y: -2)
            }

            Text(category.title)
                .font(.system(size: 12.5, weight: .regular))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 64, height: 32, alignment: .top)
                .foregroundStyle(Color.white.opacity(0.88))
        }
        .frame(width: 64)
    }
}

private struct MiniOperation: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 24, height: 36)
            .background(color.opacity(0.11))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DetailButton: View {
    let title: String
    var isDestructive = false

    var body: some View {
        Button(action: {}) {
            HStack {
                Text(title)
                    .font(.system(size: 16.5, weight: .regular))
                    .foregroundStyle(isDestructive ? Color(hex: "FF3B3B") : Color.white.opacity(0.9))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.28))
            }
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TabButton: View {
    let title: String
    let symbol: String
    let index: Int
    @Binding var selectedTab: Int

    private var isSelected: Bool { selectedTab == index }

    var body: some View {
        Button {
            selectedTab = index
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(hex: "008CFF") : Color.white.opacity(0.76))

                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color(hex: "008CFF") : Color.white.opacity(0.76))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

#Preview {
    ContentView()
}
