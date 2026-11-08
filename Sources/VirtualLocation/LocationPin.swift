import SwiftUI

/// The bottom centre is the exact map location; shadows don't affect layout.
struct LocationPin: View {
    static let size = CGSize(width: 40, height: 58)

    var body: some View {
        ZStack(alignment: .top) {
            LocationPinShape()
                .fill(LinearGradient(colors: [.teal, Color(red: 0, green: 0.46, blue: 0.51)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            LocationPinShape().strokeBorder(.white.opacity(0.96), lineWidth: 2)
            Circle().fill(.white).frame(width: 14, height: 14).offset(y: 13)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 3)
        .allowsHitTesting(false)
    }
}

struct LocationPinShape: InsettableShape {
    private var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: point(0.5, 1))
        path.addCurve(to: point(0, 0.34), control1: point(0.35, 0.76), control2: point(0, 0.58))
        path.addCurve(to: point(0.5, 0), control1: point(0, 0.14), control2: point(0.22, 0))
        path.addCurve(to: point(1, 0.34), control1: point(0.78, 0), control2: point(1, 0.14))
        path.addCurve(to: point(0.5, 1), control1: point(1, 0.58), control2: point(0.65, 0.76))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> Self {
        var result = self
        result.inset += amount
        return result
    }
}
