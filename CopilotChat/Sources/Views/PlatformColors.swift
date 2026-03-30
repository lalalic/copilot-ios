import SwiftUI

// MARK: - Platform Colors

/// Cross-platform color helpers for iOS (UIKit) and macOS (AppKit).

#if canImport(UIKit)
import UIKit

/// systemGray6 equivalent.
public let platformGray6 = Color(UIColor.systemGray6)
/// systemGray5 equivalent.
public let platformGray5 = Color(UIColor.systemGray5)
/// systemGray4 equivalent.
public let platformGray4 = Color(UIColor.systemGray4)

#elseif canImport(AppKit)
import AppKit

/// systemGray6 equivalent (light gray) for macOS.
public let platformGray6 = Color(NSColor.controlBackgroundColor)
/// systemGray5 equivalent (slightly darker) for macOS.
public let platformGray5 = Color(NSColor.separatorColor)
/// systemGray4 equivalent for macOS.
public let platformGray4 = Color(NSColor.tertiaryLabelColor)

#endif
