/// The product's names. To rename: change `appName` here, `APP_DISPLAY_NAME` in project.yml and
/// `app_name!` in Relay/src/brand.rs. Tests pin the literal once on each side.
public enum Brand {
    /// The app, as the Home Screen, the controls and every sentence in the app say it.
    public static let appName = "Pteron"
    /// The program on the computer that sends the notifications.
    public static let beaconName = "\(appName) Beacon"
}
