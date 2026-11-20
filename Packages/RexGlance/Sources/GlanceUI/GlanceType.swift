import SwiftUI

/// The widgets' type: the system font at the agent board's sizes.
public enum GlanceType {
    /// The headline: 22 pt in the small size, 20 pt in the others, bold, with digits of one width.
    public static func headline(small: Bool) -> Font { .system(size: small ? 22 : 20, weight: .bold).monospacedDigit() }
    public static let name = Font.system(size: 13, weight: .semibold)
    public static let state = Font.system(size: 12, weight: .semibold).monospacedDigit()
    public static let place = Font.system(size: 11)
    /// The Lock Screen's count.
    public static let count = Font.system(size: 24, weight: .bold, design: .rounded).monospacedDigit()
    /// Dynamic Type stops growing here: a widget's frame doesn't.
    public static let largestText = DynamicTypeSize.xxLarge
}
