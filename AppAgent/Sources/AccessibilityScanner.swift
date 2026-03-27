import Foundation

/// Describes a single interactive UI element found by the scanner.
public struct AppElement: Sendable {
    /// Sequential ref ID: "r0", "r1", etc.
    public let ref: String
    /// Element kind (button, textField, switch, slider, etc.)
    public let kind: String
    /// Label or accessibility label
    public let label: String
    /// Current value (text field content, switch state, slider value)
    public let value: String?
    /// Whether the element is enabled
    public let isEnabled: Bool
    /// Whether the element is selected
    public let isSelected: Bool
    /// Frame in screen coordinates
    public let frame: CGRect
    /// Accessibility traits description
    public let traits: String

    public init(ref: String, kind: String, label: String, value: String?,
                isEnabled: Bool, isSelected: Bool, frame: CGRect, traits: String) {
        self.ref = ref
        self.kind = kind
        self.label = label
        self.value = value
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.frame = frame
        self.traits = traits
    }

    /// Compact text description for LLM snapshot
    public var description: String {
        var desc = "\(ref) [\(kind)]"
        if !isEnabled { desc += " (disabled)" }
        if isSelected { desc += " (selected)" }
        if !label.isEmpty { desc += " \"\(label)\"" }
        if let value, !value.isEmpty { desc += " value=\"\(value)\"" }
        // Show frame position for hit-test discovered elements
        let x = Int(frame.origin.x), y = Int(frame.origin.y)
        let w = Int(frame.width), h = Int(frame.height)
        desc += " (\(x),\(y) \(w)x\(h))"
        return desc
    }
}

#if os(iOS)
import UIKit

/// Scans the iOS view hierarchy using accessibility APIs to find interactive elements.
/// Assigns sequential refs (r0, r1, ...) for agent interaction.
@MainActor
public final class AccessibilityScanner {

    /// Last scan results
    private(set) public var elements: [AppElement] = []

    /// Lookup by ref
    private var refToElement: [String: AppElement] = [:]

    /// Lookup by ref to UIView
    private var refToView: [String: UIView] = [:]

    public init() {}

    // MARK: - Scan

    /// Scan the current screen for interactive elements.
    /// Returns a tree-structured text listing suitable for LLM consumption.
    @discardableResult
    public func scan() -> String {
        elements.removeAll()
        refToElement.removeAll()
        refToView.removeAll()

        guard let window = Self.keyWindow else {
            return "Error: no active window"
        }

        var idx = 0
        var lines: [String] = []

        let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
        let screenSize = window.bounds.size
        lines.append("[\(appName)] (\(Int(screenSize.width))x\(Int(screenSize.height)))")

        scanViewTree(window, index: &idx, depth: 1, lines: &lines)

        // Hit-test probe to discover SwiftUI-rendered elements not in the UIView tree
        probeHitTest(window, index: &idx, depth: 1, lines: &lines)

        lines.append("---")
        lines.append("\(elements.count) interactive elements")

        return lines.joined(separator: "\n")
    }

    /// Get element by ref.
    public func element(for ref: String) -> AppElement? {
        refToElement[ref]
    }

    /// Get UIView by ref.
    public func view(for ref: String) -> UIView? {
        refToView[ref]
    }

    // MARK: - Hit-Test Probing

    /// Probe the screen with hit-tests to discover SwiftUI elements not in the UIView tree.
    /// SwiftUI renders buttons/text without individual UIViews, but hitTest still works.
    private func probeHitTest(_ window: UIWindow, index: inout Int, depth: Int, lines: inout [String]) {
        let bounds = window.bounds
        let step: CGFloat = 15  // probe every 15 points
        var discoveredViews = Set<ObjectIdentifier>()
        // Track already-registered views to avoid duplicates
        for view in refToView.values {
            discoveredViews.insert(ObjectIdentifier(view))
        }

        struct HitRegion {
            let view: UIView
            var minX: CGFloat
            var minY: CGFloat
            var maxX: CGFloat
            var maxY: CGFloat
        }
        var regions: [ObjectIdentifier: HitRegion] = [:]

        // Probe grid
        var y: CGFloat = 0
        while y < bounds.height {
            var x: CGFloat = 0
            while x < bounds.width {
                let point = CGPoint(x: x, y: y)
                if let hitView = window.hitTest(point, with: nil),
                   hitView !== window {
                    let id = ObjectIdentifier(hitView)
                    // Skip already-discovered views (from viewTree scan)
                    if !discoveredViews.contains(id) {
                        // Check if this view looks interactive
                        let hasGestures = hitView.gestureRecognizers?.contains(where: {
                            ($0 is UITapGestureRecognizer || $0 is UILongPressGestureRecognizer) && $0.isEnabled
                        }) ?? false
                        let hasTraits = hitView.accessibilityTraits.contains(.button) ||
                            hitView.accessibilityTraits.contains(.link)
                        let isControl = hitView is UIControl

                        if hasGestures || hasTraits || isControl {
                            if var region = regions[id] {
                                region.minX = min(region.minX, x)
                                region.minY = min(region.minY, y)
                                region.maxX = max(region.maxX, x + step)
                                region.maxY = max(region.maxY, y + step)
                                regions[id] = region
                            } else {
                                regions[id] = HitRegion(
                                    view: hitView,
                                    minX: x, minY: y,
                                    maxX: x + step, maxY: y + step
                                )
                            }
                        }
                    }
                }
                x += step
            }
            y += step
        }

        // Register discovered hit-test regions as elements
        // Sort by Y then X for consistent ordering
        let sorted = regions.values.sorted {
            if abs($0.minY - $1.minY) > step { return $0.minY < $1.minY }
            return $0.minX < $1.minX
        }

        for region in sorted {
            let view = region.view
            let frame = CGRect(
                x: region.minX, y: region.minY,
                width: region.maxX - region.minX,
                height: region.maxY - region.minY
            )
            // Skip if covers > 50% of screen (container)
            if frame.width * frame.height > bounds.width * bounds.height * 0.5 { continue }

            let ref = "r\(index)"
            let kind = classifyKind(view)
            let label = view.accessibilityLabel ?? ""
            let value = currentValue(view)
            let traits = traitsDescription(view.accessibilityTraits)

            let element = AppElement(
                ref: ref,
                kind: kind,
                label: label,
                value: value,
                isEnabled: view.isUserInteractionEnabled,
                isSelected: view.accessibilityTraits.contains(.selected),
                frame: frame,
                traits: traits
            )

            elements.append(element)
            refToElement[ref] = element
            refToView[ref] = view
            index += 1

            let indent = String(repeating: "  ", count: depth)
            lines.append("\(indent)\(element.description)")
        }
    }

    // MARK: - View Walking

    private func scanViewTree(_ view: UIView, index: inout Int, depth: Int, lines: inout [String]) {
        // Skip hidden/transparent views
        guard !view.isHidden, view.alpha > 0 else { return }

        // Use screen-coordinate frame: prefer accessibilityFrame, fall back to converted bounds
        var frame = view.accessibilityFrame
        if frame.width <= 0 || frame.height <= 0 {
            frame = view.convert(view.bounds, to: nil)
        }
        // Skip zero-size views
        guard frame.width > 0, frame.height > 0 else {
            for subview in view.subviews {
                scanViewTree(subview, index: &index, depth: depth, lines: &lines)
            }
            return
        }

        let indent = String(repeating: "  ", count: depth)

        let interactive = isInteractive(view)

        // Check if this view is interactive
        if interactive {
            let ref = "r\(index)"
            let kind = classifyKind(view)
            let label = view.accessibilityLabel ?? ""
            let value = currentValue(view)
            let traits = traitsDescription(view.accessibilityTraits)

            let element = AppElement(
                ref: ref,
                kind: kind,
                label: label,
                value: value,
                isEnabled: view.isUserInteractionEnabled,
                isSelected: view.accessibilityTraits.contains(.selected),
                frame: frame,
                traits: traits
            )

            elements.append(element)
            refToElement[ref] = element
            refToView[ref] = view
            index += 1

            lines.append("\(indent)\(element.description)")
        } else if isContainer(view) {
            // Show significant containers for tree structure
            let containerName = containerLabel(view)
            lines.append("\(indent)\(containerName)")
        }

        // Check for virtual accessibility children (SwiftUI, custom containers)
        let axChildren = collectAccessibilityChildren(view)
        if !axChildren.isEmpty {
            for child in axChildren {
                if let childView = child as? UIView {
                    scanViewTree(childView, index: &index, depth: depth + 1, lines: &lines)
                } else if let childObj = child as? NSObject {
                    scanAccessibilityObject(childObj, parentView: view, index: &index, depth: depth + 1, lines: &lines)
                }
            }
        } else if !view.isAccessibilityElement || !view.accessibilityTraits.contains(.tabBar) {
            // Recurse into subviews only if no accessibility children found
            for subview in view.subviews {
                scanViewTree(subview, index: &index, depth: depth + 1, lines: &lines)
            }
        }
    }

    /// Collect virtual accessibility children from a view (SwiftUI, containers).
    private func collectAccessibilityChildren(_ view: UIView) -> [Any] {
        if let elements = view.accessibilityElements, !elements.isEmpty {
            return elements
        }
        let count = view.accessibilityElementCount()
        if count > 0 && count != NSNotFound {
            var children: [Any] = []
            for i in 0..<count {
                if let child = view.accessibilityElement(at: i) {
                    children.append(child)
                }
            }
            if !children.isEmpty { return children }
        }
        return []
    }

    /// Scan a non-UIView accessibility object (SwiftUI elements, UIAccessibilityElement).
    private func scanAccessibilityObject(_ ax: NSObject, parentView: UIView, index: inout Int, depth: Int, lines: inout [String]) {
        let frame = ax.accessibilityFrame
        guard frame.width > 0, frame.height > 0 else { return }

        let traits = ax.accessibilityTraits
        let label = ax.accessibilityLabel ?? ""
        let indent = String(repeating: "  ", count: depth)

        let hasInteractiveTrait = traits.contains(.button) || traits.contains(.link) ||
            traits.contains(.searchField) || traits.contains(.adjustable)

        if hasInteractiveTrait || (ax.isAccessibilityElement && !label.isEmpty) {
            let ref = "r\(index)"
            let kind: String
            if traits.contains(.button) { kind = "button" }
            else if traits.contains(.link) { kind = "link" }
            else if traits.contains(.searchField) { kind = "searchField" }
            else if traits.contains(.adjustable) { kind = "adjustable" }
            else if traits.contains(.staticText) { kind = "text" }
            else if traits.contains(.image) { kind = "image" }
            else { kind = "view" }

            let value = ax.accessibilityValue

            let element = AppElement(
                ref: ref,
                kind: kind,
                label: label,
                value: value,
                isEnabled: true,
                isSelected: traits.contains(.selected),
                frame: frame,
                traits: traitsDescription(traits)
            )

            elements.append(element)
            refToElement[ref] = element
            refToView[ref] = parentView // map to parent for coordinate-based interaction
            index += 1

            lines.append("\(indent)\(element.description)")
        }

        // Recurse into child accessibility elements
        if let children = ax.accessibilityElements {
            for child in children {
                if let childView = child as? UIView {
                    scanViewTree(childView, index: &index, depth: depth + 1, lines: &lines)
                } else if let childAx = child as? NSObject {
                    scanAccessibilityObject(childAx, parentView: parentView, index: &index, depth: depth + 1, lines: &lines)
                }
            }
        } else {
            let count = ax.accessibilityElementCount()
            if count > 0 && count != NSNotFound {
                for i in 0..<count {
                    if let child = ax.accessibilityElement(at: i) {
                        if let childView = child as? UIView {
                            scanViewTree(childView, index: &index, depth: depth + 1, lines: &lines)
                        } else if let childAx = child as? NSObject {
                            scanAccessibilityObject(childAx, parentView: parentView, index: &index, depth: depth + 1, lines: &lines)
                        }
                    }
                }
            }
        }
    }

    /// Whether a view is a significant container worth showing in the tree.
    private func isContainer(_ view: UIView) -> Bool {
        // Navigation bars, tab bars, toolbars, scroll views, stack views
        if view is UINavigationBar { return true }
        if view is UITabBar { return true }
        if view is UIToolbar { return true }
        if view is UIScrollView { return true }
        if view is UIStackView { return true }
        // Views with accessibility labels (developer-annotated containers)
        if view.accessibilityLabel != nil, !view.accessibilityLabel!.isEmpty { return true }
        // Header traits
        if view.accessibilityTraits.contains(.header) { return true }
        return false
    }

    /// Descriptive label for a container view.
    private func containerLabel(_ view: UIView) -> String {
        if let label = view.accessibilityLabel, !label.isEmpty {
            return "[\(label)]"
        }
        if view is UINavigationBar { return "[Navigation Bar]" }
        if view is UITabBar { return "[Tab Bar]" }
        if view is UIToolbar { return "[Toolbar]" }
        if view is UIScrollView { return "[Scroll View]" }
        if view is UIStackView { return "[Stack]" }
        return "[Container]"
    }

    // MARK: - Classification

    private func isInteractive(_ view: UIView) -> Bool {
        // The window itself is never an interactive element
        if view is UIWindow { return false }

        // Explicit accessibility element with actionable traits
        let traits = view.accessibilityTraits
        if traits.contains(.button) || traits.contains(.link) ||
           traits.contains(.searchField) || traits.contains(.adjustable) {
            return true
        }

        // Common interactive UIKit types
        if view is UIButton || view is UISwitch || view is UISlider ||
           view is UITextField || view is UITextView || view is UISegmentedControl ||
           view is UIStepper || view is UIDatePicker || view is UIPageControl {
            return true
        }

        // Tap gesture recognizers — but only on small views (not container views)
        // Container views (hosting views, scroll views) often have gesture recognizers
        // that aren't interactive buttons
        if let gestures = view.gestureRecognizers,
           gestures.contains(where: { $0 is UITapGestureRecognizer && $0.isEnabled }) {
            // Skip if the view covers > 50% of the screen (likely a container)
            if let window = view.window {
                let screenArea = window.bounds.width * window.bounds.height
                let viewArea = view.bounds.width * view.bounds.height
                if viewArea > screenArea * 0.5 { return false }
            }
            return true
        }

        return false
    }

    private func classifyKind(_ view: UIView) -> String {
        if view is UIButton { return "button" }
        if view is UISwitch { return "switch" }
        if view is UISlider { return "slider" }
        if view is UITextField { return "textField" }
        if view is UITextView { return "textView" }
        if view is UISegmentedControl { return "segmentedControl" }
        if view is UIStepper { return "stepper" }
        if view is UIDatePicker { return "datePicker" }
        if view is UIPageControl { return "pageControl" }

        let traits = view.accessibilityTraits
        if traits.contains(.button) { return "button" }
        if traits.contains(.link) { return "link" }
        if traits.contains(.searchField) { return "searchField" }
        if traits.contains(.adjustable) { return "adjustable" }
        if traits.contains(.image) { return "image" }
        if traits.contains(.staticText) { return "text" }

        return "view"
    }

    private func currentValue(_ view: UIView) -> String? {
        if let textField = view as? UITextField {
            return textField.text
        }
        if let textView = view as? UITextView {
            return textView.text.isEmpty ? nil : String(textView.text.prefix(100))
        }
        if let toggle = view as? UISwitch {
            return toggle.isOn ? "on" : "off"
        }
        if let slider = view as? UISlider {
            return String(format: "%.2f", slider.value)
        }
        if let segment = view as? UISegmentedControl {
            if segment.selectedSegmentIndex >= 0 {
                return segment.titleForSegment(at: segment.selectedSegmentIndex)
            }
        }
        return view.accessibilityValue
    }

    private func traitsDescription(_ traits: UIAccessibilityTraits) -> String {
        var parts: [String] = []
        if traits.contains(.button) { parts.append("button") }
        if traits.contains(.link) { parts.append("link") }
        if traits.contains(.searchField) { parts.append("search") }
        if traits.contains(.image) { parts.append("image") }
        if traits.contains(.selected) { parts.append("selected") }
        if traits.contains(.adjustable) { parts.append("adjustable") }
        if traits.contains(.header) { parts.append("header") }
        if traits.contains(.staticText) { parts.append("text") }
        return parts.joined(separator: ",")
    }

    // MARK: - Key Window

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}
#endif
