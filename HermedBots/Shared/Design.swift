import SwiftUI

extension EnvironmentValues {
    /// Faux en mode test et quand macOS demande moins d'animations : les captures de référence exigent une image fixe
    @Entry var motion = true
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// Les couleurs de l'app : un dégradé de marque et un dégradé par bot, indexé par `Bot.palette`
enum Palette {
    static let brand = [Color(rgb: 0x8E54E9), Color(rgb: 0x4776E6), Color(rgb: 0x00C6FF)]

    private static let bots: [(UInt32, UInt32)] = [
        (0xFF5F6D, 0xFFA45C), (0x2193B0, 0x6DD5ED), (0x7F00FF, 0xE100FF), (0x11998E, 0x38EF7D),
        (0xF12711, 0xF5AF19), (0x4776E6, 0x8E54E9), (0xEC008C, 0xFC6767), (0x00B4DB, 0x0083B0),
        (0x56AB2F, 0xA8E063), (0x8E2DE2, 0x4A00E0), (0xFC4A1A, 0xF7B733), (0x43CEA2, 0x185A9D),
    ]

    static func colors(_ bot: Bot) -> [Color] {
        let pair = bots[bot.palette % bots.count]
        return [Color(rgb: pair.0), Color(rgb: pair.1)]
    }

    static func gradient(_ colors: [Color]) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Le visage d'un bot : ses initiales sur son dégradé ; un anneau tourne autour pendant qu'il travaille, une pastille dit qu'il attend une réponse
struct BotAvatar: View {
    let bot: Bot
    var size: CGFloat = 28
    var activity = ConversationMachine.Activity.idle

    var body: some View {
        let colors = Palette.colors(bot)
        Text(verbatim: bot.monogram)
            .font(.system(size: size * (bot.monogram.count > 1 ? 0.38 : 0.46), weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .frame(width: size, height: size)
            .background(Palette.gradient(colors), in: .circle)
            .overlay {
                if activity != .idle { WorkingRing(colors: activity == .waiting ? [.orange, .yellow] : colors).padding(-max(2, size * 0.09)) }
            }
            .overlay(alignment: .bottomTrailing) {
                if activity == .waiting {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: max(7, size * 0.24), weight: .bold))
                        .foregroundStyle(.white)
                        .padding(max(2, size * 0.07))
                        .background(.orange, in: .circle)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
            .accessibilityHidden(true)
    }
}

/// L'anneau d'activité : un dégradé angulaire qui tourne, fixe quand le mouvement est coupé
private struct WorkingRing: View {
    let colors: [Color]
    @Environment(\.motion) private var motion
    @State private var turned = false

    var body: some View {
        Circle()
            .strokeBorder(AngularGradient(colors: colors + [colors[0].opacity(0)], center: .center), lineWidth: 2)
            .rotationEffect(.degrees(turned ? 360 : 0))
            .onAppear {
                guard motion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { turned = true }
            }
    }
}

/// Une aurore : un dégradé maillé dont le centre dérive lentement ; immobile quand le mouvement est coupé
struct Aurora: View {
    let colors: [Color]

    @Environment(\.motion) private var motion

    var body: some View {
        TimelineView(.animation(paused: !motion)) { context in
            let time = motion ? context.date.timeIntervalSinceReferenceDate : 0
            MeshGradient(width: 3, height: 3, points: Self.points(time), colors: Self.grid(colors))
        }
    }

    private static func points(_ time: Double) -> [SIMD2<Float>] {
        let x = Float(sin(time * 0.7)) * 0.18, y = Float(cos(time * 0.5)) * 0.18, edge = Float(sin(time * 0.4)) * 0.12
        return [[0, 0], [0.5 + edge, 0], [1, 0],
                [0, 0.5 - edge], [0.5 + x, 0.5 + y], [1, 0.5 + edge],
                [0, 1], [0.5 - edge, 1], [1, 1]]
    }

    /// Neuf couleurs pour la grille 3 × 3, prises en boucle dans la liste donnée
    private static func grid(_ colors: [Color]) -> [Color] {
        (0..<9).map { colors[($0 * 2 + $0 / 3) % colors.count] }
    }
}

/// Une sphère d'aurore avec son halo : l'emblème de l'accueil et du fil vide
struct AuroraOrb: View {
    let colors: [Color]
    var size: CGFloat = 120

    var body: some View {
        ZStack {
            Aurora(colors: colors).clipShape(.circle).blur(radius: size * 0.3).opacity(0.55).frame(width: size * 1.3, height: size * 1.3)
            Aurora(colors: colors).clipShape(.circle).frame(width: size, height: size)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        }
        .accessibilityHidden(true)
    }
}

/// Une carte d'avis teintée : l'icône de sa nature, puis son contenu ; les bandeaux de l'app la partagent
struct NoticeCard<Content: View>: View {
    let tint: Color
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.body.weight(.semibold)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) { content }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.28)))
    }
}

/// Trois points qui ondulent pendant que le bot répond ; immobiles quand le mouvement est coupé
struct TypingDots: View {
    var tint: Color = .secondary
    @Environment(\.motion) private var motion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !motion)) { context in
            let time = motion ? context.date.timeIntervalSinceReferenceDate : 0
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(tint).frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * max(0, sin(time * 5 - Double(index) * 0.8)))
                        .offset(y: motion ? -2.5 * max(0, sin(time * 5 - Double(index) * 0.8)) : 0)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Un bouton sans chrome qui s'enfonce à 97 % sous le clic
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
