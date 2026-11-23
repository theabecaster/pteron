import CoreGraphics
import Testing
@testable import Pteron

/// Where the offline screen puts the illustration and the card (`OfflineLayout.decide`).
struct OfflineLayoutTests {
    private let vertical = Division(frame: CGRect(x: 475.5, y: 0, width: 0, height: 669), isActive: false)
    private let horizontal = Division(frame: CGRect(x: 0, y: 475.5, width: 669, height: 0), isActive: false)

    private func decide(_ w: CGFloat, _ h: CGFloat, at origin: CGPoint = .zero, _ d: Division?) -> OfflineLayout {
        OfflineLayout.decide(size: CGSize(width: w, height: h), origin: origin, division: d)
    }

    @Test func unfoldedLandscapeIsTwoPagesWithTheCardOnTheRight() {
        // The vertical bar takes 84 pt on the trailing edge, so the right page is the smaller one; the
        // card still goes there, beside the illustration.
        let l = decide(867, 649, vertical)
        #expect(l.kind == .sideBySide)
        #expect(l.art == CGRect(x: 0, y: 0, width: 463.5, height: 649))
        #expect(l.card == CGRect(x: 487.5, y: 0, width: 379.5, height: 649))
    }

    @Test func unfoldedPortraitIsTwoPagesWithTheCardBelow() {
        // Inside the status bar: the crease is 44 pt higher in the root's coordinates.
        let d = Division(frame: horizontal.frame.offsetBy(dx: 0, dy: -44), isActive: false)
        let l = decide(669, 887, d)
        #expect(l.kind == .stacked)
        #expect(l.art == CGRect(x: 0, y: 0, width: 669, height: 419.5))
        #expect(l.card == CGRect(x: 0, y: 443.5, width: 669, height: 443.5))
    }

    @Test func nothingTouchesTheCrease() {
        let bent = Division(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: true)
        let l = decide(951, 669, bent)
        #expect(l.art!.maxX <= 455.5 - OfflineLayout.gutter)
        #expect(l.card.minX >= 495.5 + OfflineLayout.gutter)
    }

    @Test func aSidebarOverTheLeftPageLeavesTheCardAloneOnTheRight() {
        // Sidebar 261 pt wide: 214.5 pt of the left page left, too narrow for the illustration.
        let l = decide(606, 649, at: CGPoint(x: 261, y: 0), vertical)
        #expect(l.kind == .single)
        #expect(l.card == CGRect(x: 226.5, y: 0, width: 379.5, height: 649))
    }

    @Test func aSidebarUpToTheCreaseLeavesOnePage() {
        let l = decide(391, 649, at: CGPoint(x: 476, y: 0), vertical)
        #expect(l == OfflineLayout(kind: .single, card: CGRect(x: 0, y: 0, width: 391, height: 649), art: nil))
    }

    @Test func theKeyboardSendsTheCardToTheTopPage() {
        // Portrait with the keyboard up: 160 pt left under the crease.
        let l = decide(669, 636, horizontal)
        #expect(l.kind == .single)
        #expect(l.card == CGRect(x: 0, y: 0, width: 669, height: 463.5))
    }

    @Test(arguments: [(466.0, 678.0), (475, 669), (402, 874), (874, 402), (956, 440)])
    func withoutACreaseTheCardIsCentered(w: Double, h: Double) {
        let l = decide(w, h, nil)
        #expect(l == OfflineLayout(kind: .single, card: CGRect(x: 0, y: 0, width: w, height: h), art: nil))
    }

    @Test func aCreaseOutsideTheScreenIsIgnored() {
        // Half of the inner screen still sees the crease, at its edge.
        let l = decide(475, 669, at: CGPoint(x: 476, y: 0), vertical)
        #expect(l.kind == .single)
        #expect(l.card.width == 475)
    }
}
