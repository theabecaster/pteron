import SwiftUI
import Testing
import UIKit

/// SwiftUI screens in a window of their own, for tests that read what UIKit made of them: the
/// navigation stack, a list's size, the elements VoiceOver reads.
@MainActor
enum Hosted {
    /// - Parameter safeArea: the safe area the view gets, in place of the one the simulator's screen
    ///   gives the window (a vertical bar's column, a Dynamic Island), with the navigation bar
    ///   horizontal as on any iPhone, so a measurement is the same on every simulator (the Duo's
    ///   would otherwise move it into its vertical bar). Nil keeps the screen's.
    static func window<V: View>(_ view: V, size: CGSize = CGSize(width: 402, height: 874),
                                category: UIContentSizeCategory = .large, safeArea: EdgeInsets? = nil) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        window.frame = CGRect(origin: .zero, size: size)
        window.traitOverrides.preferredContentSizeCategory = category
        if let safeArea {
            var root = AnyView(view)
            if #available(iOS 27.1, *) { root = AnyView(view.toolbarVerticalBehavior(.disabled)) }
            let host = UIHostingController(rootView: AnyView(root.safeAreaPadding(safeArea)))
            host.safeAreaRegions = []
            window.rootViewController = host
        } else {
            window.rootViewController = UIHostingController(rootView: view)
        }
        window.makeKeyAndVisible()
        return window
    }

    /// Lets the window lay out until `done`, for up to 3 s. True when it was done.
    static func settle(_ done: () -> Bool) async -> Bool {
        for _ in 0..<30 {
            if done() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return done()
    }

    static func eventually<T>(_ find: () -> T?, sourceLocation: SourceLocation = #_sourceLocation) async throws -> T {
        var found: T?
        _ = await settle { found = find(); return found != nil }
        return try #require(found, sourceLocation: sourceLocation)
    }

    static func navigationController(in vc: UIViewController?) -> UINavigationController? {
        guard let vc else { return nil }
        if let nav = vc as? UINavigationController { return nav }
        for child in vc.children {
            if let nav = navigationController(in: child) { return nav }
        }
        return nil
    }

    static func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// SwiftUI builds its accessibility elements only while an assistive technology asks for
    /// them. This turns the simulator's automation mode on or off, as UI tests do, so a test can
    /// read them as VoiceOver would. False when the simulator has no such switch.
    static func setAccessibility(on: Bool) -> Bool {
        guard let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let sym = dlsym(lib, "_AXSSetAutomationEnabled") else { return false }
        typealias Set = @convention(c) (Int32) -> Void
        unsafeBitCast(sym, to: Set.self)(on ? 1 : 0)
        return true
    }

    /// Every element with a label under `view`, in reading order; an element can show up more
    /// than once, through its container and through its view.
    static func accessibilityElements(in view: UIView) -> [NSObject] {
        var out: [NSObject] = []
        func walk(_ o: NSObject) {
            if o.isAccessibilityElement || o.accessibilityLabel != nil { out.append(o) }
            for e in (o.accessibilityElements ?? []) {
                if let e = e as? NSObject, e !== o { walk(e) }
            }
            let count = o.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for i in 0..<count {
                    if let e = o.accessibilityElement(at: i) as? NSObject, e !== o { walk(e) }
                }
            }
            if let v = o as? UIView { v.subviews.forEach(walk) }
        }
        walk(view)
        return out
    }
}
