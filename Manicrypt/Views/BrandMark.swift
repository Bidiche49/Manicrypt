import SwiftUI

/// Un crochet (« [ » gauche ou « ] » droit) dessiné sur canvas 1024, mis à l'échelle du rect.
/// Coordonnées identiques à `design_manic/registry.py` (source de vérité — ne pas diverger).
struct MCBracket: Shape {
    var right: Bool
    func path(in rect: CGRect) -> Path {
        let u = min(rect.width, rect.height) / 1024
        var p = Path()
        if right {
            p.move(to: CGPoint(x: 604 * u, y: 336 * u))
            p.addLine(to: CGPoint(x: 680 * u, y: 336 * u))
            p.addLine(to: CGPoint(x: 680 * u, y: 688 * u))
            p.addLine(to: CGPoint(x: 604 * u, y: 688 * u))
        } else {
            p.move(to: CGPoint(x: 420 * u, y: 336 * u))
            p.addLine(to: CGPoint(x: 344 * u, y: 336 * u))
            p.addLine(to: CGPoint(x: 344 * u, y: 688 * u))
            p.addLine(to: CGPoint(x: 420 * u, y: 688 * u))
        }
        return p
    }
}

/// Glyphe « crochets » de Manicrypt, animable.
/// `sealed` : 1 = chiffré (crochets serrés sur la cellule) · 0 = déchiffré (crochets écartés
/// et estompés, la cellule s'allonge). S'anime via `.animation(value:)` / `withAnimation`
/// côté parent (offset + scaleEffect + opacity sont interpolés automatiquement).
struct CrochetsGlyph: View {
    var sealed: Double = 1
    var color: Color

    private let spread: CGFloat = 175      // écartement max des crochets (unités canvas 1024)
    private let wordStretch: CGFloat = 2.6 // allongement max de la cellule

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let u = s / 1024
            let open = 1 - sealed
            let stroke = StrokeStyle(lineWidth: 76 * u, lineCap: .round, lineJoin: .round)
            let bracketOpacity = 0.12 + 0.88 * sealed

            ZStack {
                MCBracket(right: false).stroke(color, style: stroke)
                    .offset(x: -spread * u * open)
                    .opacity(bracketOpacity)
                MCBracket(right: true).stroke(color, style: stroke)
                    .offset(x: spread * u * open)
                    .opacity(bracketOpacity)
                RoundedRectangle(cornerRadius: 30 * u, style: .continuous)
                    .fill(color)
                    .frame(width: 120 * u, height: 120 * u)
                    .scaleEffect(x: 1 + open * wordStretch, anchor: .center)
                    .position(x: s / 2, y: s / 2)
            }
            .frame(width: s, height: s)
        }
    }
}

/// Variante « feedback » du glyphe : joue une seule fois, à l'apparition, l'animation
/// de SCELLEMENT (`sealing: true`, chiffrement — les crochets se referment) ou
/// d'OUVERTURE (`sealing: false`, déchiffrement — les crochets s'écartent et s'estompent).
///
/// `size` est l'encombrement layout ; l'artwork est agrandi pour le remplir (le canvas
/// 1024 réserve de larges marges autour des crochets) et peut déborder légèrement du
/// cadre pendant la phase ouverte — prévoir un peu d'air autour (padding du parent).
/// Pour rejouer l'animation à chaque présentation, changer l'identité de la vue
/// (`.id(...)`) côté appelant.
struct AnimatedCrochetsGlyph: View {
    let sealing: Bool
    let color: Color
    var size: CGFloat = 18
    var delay: Double = 0.12

    @State private var sealed: Double

    init(sealing: Bool, color: Color, size: CGFloat = 18, delay: Double = 0.12) {
        self.sealing = sealing
        self.color = color
        self.size = size
        self.delay = delay
        _sealed = State(initialValue: sealing ? 0 : 1)
    }

    var body: some View {
        CrochetsGlyph(sealed: sealed, color: color)
            // Les crochets (y compris leur trait) occupent ~42 % de la hauteur du
            // canvas : on dessine à 2.4× puis on rend l'encombrement réel `size`.
            .frame(width: size * 2.4, height: size * 2.4)
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.72).delay(delay)) {
                    sealed = sealing ? 1 : 0
                }
            }
    }
}

/// Mini-icône d'app Manicrypt : squircle + dégradé de marque (indigo → violet) + crochets.
/// `sealed` pilote l'animation « enserrer / libérer » (cf. design_manic/glyphs/manicrypt/ANIMATION.md).
struct ManicryptMark: View {
    var size: CGFloat = 64
    var sealed: Double = 1

    private let g1 = Color(red: 0.263, green: 0.220, blue: 0.792) // #4338CA
    private let g2 = Color(red: 0.486, green: 0.227, blue: 0.929) // #7C3AED

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(LinearGradient(colors: [g1, g2],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            CrochetsGlyph(sealed: sealed, color: Color(white: 0.96))
        }
        .frame(width: size, height: size)
    }
}
