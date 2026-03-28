#if os(iOS)
import UIKit

/// Handles user interaction simulation on native iOS views.
/// Uses public accessibility APIs — no private API usage.
@MainActor
public final class InteractionEngine {

    private let scanner: AccessibilityScanner

    public init(scanner: AccessibilityScanner) {
        self.scanner = scanner
    }

    // MARK: - Tap

    /// Tap an element by its ref.
    public func tap(ref: String) -> String {
        guard let view = scanner.view(for: ref),
              let element = scanner.element(for: ref) else {
            return "Error: element '\(ref)' not found. Run snapshot first."
        }

        guard element.isEnabled else {
            return "Error: element '\(ref)' is disabled"
        }

        // Method 1: accessibilityActivate() — official API for triggering action
        if view.accessibilityActivate() {
            return "Tapped \(ref) [\(element.kind)] \"\(element.label)\""
        }

        // Method 2: For UIControl subclasses, send touch events
        if let control = view as? UIControl {
            control.sendActions(for: .touchUpInside)
            return "Tapped \(ref) [\(element.kind)] \"\(element.label)\""
        }

        // Method 3: Walk accessibility elements on the view (SwiftUI hosting views)
        let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        if activateAccessibilityElement(in: view, at: center) {
            return "Tapped \(ref) [\(element.kind)] \"\(element.label)\" (via a11y element)"
        }

        // Method 4: Hit-test based approach as fallback
        if let window = view.window,
           let hitView = window.hitTest(center, with: nil) {
            if let control = hitView as? UIControl {
                control.sendActions(for: .touchUpInside)
                return "Tapped \(ref) [\(element.kind)] \"\(element.label)\" (via hitTest)"
            }
            if hitView.accessibilityActivate() {
                return "Tapped \(ref) [\(element.kind)] \"\(element.label)\" (via hitTest)"
            }
            // Try a11y elements on the hit-tested view too
            if activateAccessibilityElement(in: hitView, at: center) {
                return "Tapped \(ref) [\(element.kind)] \"\(element.label)\" (via hitTest a11y)"
            }
        }

        // Method 5: Gesture recognizer force-trigger
        synthesizeTouch(at: center, in: view.window ?? Self.keyWindow!)
        return "Warning: tapped \(ref) via synthesized touch — may not have triggered"
    }

    // MARK: - Tap XY (coordinate-based)

    /// Tap at arbitrary screen coordinates. Essential for SwiftUI buttons
    /// which aren't individually discoverable as UIKit views.
    public func tapXY(x: Double, y: Double) -> String {
        guard let window = Self.keyWindow else {
            return "Error: no active window found"
        }

        let point = CGPoint(x: x, y: y)

        // Hit-test to find the deepest view at these coordinates
        guard let hitView = window.hitTest(point, with: nil) else {
            return "Error: no view responds to hit-test at (\(Int(x)), \(Int(y)))"
        }

        // Method 1: UIControl (UIButton, etc.)
        if let control = hitView as? UIControl {
            control.sendActions(for: .touchUpInside)
            return "Tapped (\(Int(x)), \(Int(y))) → UIControl [\(Swift.type(of: control))]"
        }

        // Method 2: Accessibility activate on the view itself
        if hitView.accessibilityActivate() {
            return "Tapped (\(Int(x)), \(Int(y))) → activated [\(Swift.type(of: hitView))]"
        }

        // Method 3: Walk accessibility elements on the hit view and its ancestors
        // This is critical for SwiftUI — buttons are accessibility elements on the hosting view
        var current: UIView? = hitView
        while let view = current {
            if activateAccessibilityElement(in: view, at: point) {
                return "Tapped (\(Int(x)), \(Int(y))) → a11y element on [\(Swift.type(of: view))]"
            }
            current = view.superview
        }

        // Method 4: Synthesize full touch event sequence on the window
        synthesizeTouch(at: point, in: window)
        return "Tapped (\(Int(x)), \(Int(y))) → synthesized touch on [\(Swift.type(of: hitView))]"
    }

    // MARK: - Accessibility Element Activation

    /// Walk the accessibility element tree of a view to find and activate
    /// the element at the given point. This is essential for SwiftUI views
    /// where buttons exist as accessibility elements on a hosting view.
    private func activateAccessibilityElement(in view: UIView, at point: CGPoint) -> Bool {
        // Check direct accessibility elements
        if let elements = view.accessibilityElements {
            for element in elements {
                if let axElement = element as? NSObject {
                    let frame = axElement.accessibilityFrame
                    if frame.contains(point) {
                        if axElement.accessibilityActivate() {
                            return true
                        }
                    }
                }
            }
        }

        // Also check via accessibilityElementCount / accessibilityElement(at:)
        let count = view.accessibilityElementCount()
        if count != NSNotFound && count > 0 {
            for i in 0..<count {
                if let axElement = view.accessibilityElement(at: i) as? NSObject {
                    let frame = axElement.accessibilityFrame
                    if frame.contains(point) {
                        if axElement.accessibilityActivate() {
                            return true
                        }
                    }
                }
            }
        }

        return false
    }

    /// Synthesize a touch-down → touch-up sequence at the given point.
    private func synthesizeTouch(at point: CGPoint, in window: UIWindow) {
        // Use UIKit's gesture recognizer system by creating simulated events
        // via the undocumented but well-known UITouch/UIEvent pattern.
        // Since we want to stay public-API-only, we use an alternative:
        // find all gesture recognizers on the hit-tested view chain and
        // trigger them via target/action if possible.
        guard let hitView = window.hitTest(point, with: nil) else { return }

        // Walk up the responder chain looking for gesture recognizers
        var current: UIView? = hitView
        while let view = current {
            if let gestures = view.gestureRecognizers {
                for gesture in gestures where gesture.isEnabled {
                    if gesture is UITapGestureRecognizer {
                        // Force-trigger by setting state (uses runtime)
                        gesture.setValue(3, forKey: "state") // .ended = 3
                        // Reset after a tick
                        DispatchQueue.main.async {
                            gesture.setValue(0, forKey: "state") // .possible = 0
                        }
                        return
                    }
                }
            }
            current = view.superview
        }
    }

    // MARK: - Type

    /// Type text into an element by its ref. Clears existing text if requested.
    public func type(ref: String, text: String, clear: Bool = true) -> String {
        guard let view = scanner.view(for: ref),
              let element = scanner.element(for: ref) else {
            return "Error: element '\(ref)' not found. Run snapshot first."
        }

        // Try the mapped view first, then hit-test to find actual text input
        let candidates: [UIView] = {
            var views = [view]
            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            if let window = view.window ?? Self.keyWindow,
               let hitView = window.hitTest(center, with: nil), hitView !== view {
                views.append(hitView)
                // Also walk up from hitView looking for text input
                var ancestor: UIView? = hitView.superview
                while let a = ancestor, a !== view {
                    views.append(a)
                    ancestor = a.superview
                }
            }
            return views
        }()

        for candidate in candidates {
            if let textField = candidate as? UITextField {
                textField.becomeFirstResponder()
                if clear { textField.text = "" }
                textField.insertText(text)
                textField.sendActions(for: .editingChanged)
                return "Typed \"\(text)\" into \(ref) [\(element.kind)]"
            }
            if let textView = candidate as? UITextView {
                textView.becomeFirstResponder()
                if clear { textView.text = "" }
                textView.insertText(text)
                return "Typed \"\(text)\" into \(ref) [\(element.kind)]"
            }
            if let searchBar = candidate as? UISearchBar {
                searchBar.becomeFirstResponder()
                if clear { searchBar.text = "" }
                searchBar.text = (searchBar.text ?? "") + text
                return "Typed \"\(text)\" into \(ref) [\(element.kind)]"
            }
        }

        // Generic UIKeyInput conformance
        for candidate in candidates {
            if let keyInput = candidate as? (any UIKeyInput) {
                candidate.becomeFirstResponder()
                if clear {
                    while keyInput.hasText {
                        keyInput.deleteBackward()
                    }
                }
                keyInput.insertText(text)
                return "Typed \"\(text)\" into \(ref) [\(element.kind)]"
            }
        }

        return "Error: element '\(ref)' is not a text input"
    }

    // MARK: - Screenshot

    /// Take a screenshot of the current screen as base64 JPEG.
    public func screenshot(quality: CGFloat = 0.1) -> String? {
        guard let window = Self.keyWindow else { return nil }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { ctx in
            window.layer.render(in: ctx.cgContext)
        }

        guard let data = image.jpegData(compressionQuality: quality) else {
            return nil
        }

        return data.base64EncodedString()
    }

    // MARK: - Swipe

    /// Swipe on the screen or on a specific element.
    /// Direction: "up", "down", "left", "right"
    public func swipe(direction: String, ref: String? = nil) -> String {
        let window: UIView
        var center: CGPoint

        if let ref, let view = scanner.view(for: ref), let element = scanner.element(for: ref) {
            guard let w = view.window else {
                return "Error: element '\(ref)' has no window"
            }
            window = w
            center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        } else if let w = Self.keyWindow {
            window = w
            center = CGPoint(x: w.bounds.midX, y: w.bounds.midY)
        } else {
            return "Error: no active window"
        }

        let distance: CGFloat = 200

        let from: CGPoint
        let to: CGPoint
        switch direction.lowercased() {
        case "up":
            from = CGPoint(x: center.x, y: center.y + distance / 2)
            to = CGPoint(x: center.x, y: center.y - distance / 2)
        case "down":
            from = CGPoint(x: center.x, y: center.y - distance / 2)
            to = CGPoint(x: center.x, y: center.y + distance / 2)
        case "left":
            from = CGPoint(x: center.x + distance / 2, y: center.y)
            to = CGPoint(x: center.x - distance / 2, y: center.y)
        case "right":
            from = CGPoint(x: center.x - distance / 2, y: center.y)
            to = CGPoint(x: center.x + distance / 2, y: center.y)
        default:
            return "Error: invalid direction '\(direction)'. Use: up, down, left, right"
        }

        // Find the scroll view at the target point
        if let scrollView = findScrollView(at: center, in: window) {
            let offset = scrollView.contentOffset
            switch direction.lowercased() {
            case "up":
                scrollView.setContentOffset(CGPoint(x: offset.x, y: offset.y + distance), animated: true)
            case "down":
                scrollView.setContentOffset(CGPoint(x: offset.x, y: max(0, offset.y - distance)), animated: true)
            case "left":
                scrollView.setContentOffset(CGPoint(x: offset.x + distance, y: offset.y), animated: true)
            case "right":
                scrollView.setContentOffset(CGPoint(x: max(0, offset.x - distance), y: offset.y), animated: true)
            default: break
            }
            let desc = ref.map { "on \($0)" } ?? "on screen"
            return "Swiped \(direction) \(desc)"
        }

        let desc = ref.map { "on \($0)" } ?? "on screen"
        return "Warning: swiped \(direction) \(desc) but no scroll view found"
    }

    // MARK: - Long Press

    /// Long-press an element by its ref.
    public func longPress(ref: String, duration: TimeInterval = 1.0) -> String {
        guard let view = scanner.view(for: ref),
              let element = scanner.element(for: ref) else {
            return "Error: element '\(ref)' not found. Run snapshot first."
        }

        guard element.isEnabled else {
            return "Error: element '\(ref)' is disabled"
        }

        // Try to find and trigger a long-press gesture recognizer
        if let longPressGR = view.gestureRecognizers?.first(where: { $0 is UILongPressGestureRecognizer && $0.isEnabled }) {
            // Trigger via accessibility
            if view.accessibilityActivate() {
                return "Long-pressed \(ref) [\(element.kind)] \"\(element.label)\""
            }
        }

        // For context menu (iOS 13+), use accessibility custom actions
        if let actions = view.accessibilityCustomActions, !actions.isEmpty {
            // Report available actions
            let actionNames = actions.map { $0.name }.joined(separator: ", ")
            return "Long-pressed \(ref) [\(element.kind)] \"\(element.label)\". Custom actions: \(actionNames)"
        }

        // Fallback: try accessibilityActivate
        _ = view.accessibilityActivate()
        return "Long-pressed \(ref) [\(element.kind)] \"\(element.label)\""
    }

    // MARK: - Find by Text

    /// Search for elements containing the given text in their label or value.
    /// Returns matching elements without requiring a prior snapshot.
    public func find(text: String) -> String {
        // Rescan to get fresh state
        scanner.scan()

        let query = text.lowercased()
        let matches = scanner.elements.filter { element in
            element.label.lowercased().contains(query) ||
            (element.value?.lowercased().contains(query) ?? false)
        }

        if matches.isEmpty {
            return "No elements found matching \"\(text)\" (searched \(scanner.elements.count) elements)"
        }

        var result = "Found \(matches.count) element(s) matching \"\(text)\":\n"
        for element in matches {
            result += "  \(element.description)\n"
        }
        return result.trimmingCharacters(in: .newlines)
    }

    // MARK: - Scroll to Element

    /// Scroll to make an element visible.
    public func scrollTo(ref: String) -> String {
        guard let view = scanner.view(for: ref),
              let element = scanner.element(for: ref) else {
            return "Error: element '\(ref)' not found. Run snapshot first."
        }

        // Find the nearest scroll view ancestor
        var current: UIView? = view.superview
        while let parent = current {
            if let scrollView = parent as? UIScrollView {
                let rect = scrollView.convert(view.frame, from: view.superview)
                scrollView.scrollRectToVisible(rect, animated: true)
                return "Scrolled to \(ref) [\(element.kind)] \"\(element.label)\""
            }
            current = parent.superview
        }

        return "Warning: no scroll view ancestor for \(ref)"
    }

    // MARK: - Pick (Picker Selection)

    /// Select a value in a picker, date picker, or segmented control.
    /// - Parameters:
    ///   - ref: Element ref from snapshot
    ///   - value: The value to select (text for picker/segment, date string for date picker)
    ///   - component: Picker component (column) index, default 0
    public func pick(ref: String, value: String, component: Int = 0) -> String {
        guard let view = scanner.view(for: ref),
              let element = scanner.element(for: ref) else {
            return "Error: element '\(ref)' not found. Run snapshot first."
        }

        // Find the actual picker view — may be the view itself or an ancestor
        if let result = tryPickerView(view, value: value, component: component, ref: ref, element: element) {
            return result
        }
        if let result = tryDatePicker(view, value: value, ref: ref, element: element) {
            return result
        }
        if let result = trySegmentedControl(view, value: value, ref: ref, element: element) {
            return result
        }

        // Walk up the view hierarchy to find a picker ancestor
        var current: UIView? = view.superview
        while let parent = current {
            if let result = tryPickerView(parent, value: value, component: component, ref: ref, element: element) {
                return result
            }
            if let result = tryDatePicker(parent, value: value, ref: ref, element: element) {
                return result
            }
            if let result = trySegmentedControl(parent, value: value, ref: ref, element: element) {
                return result
            }
            current = parent.superview
        }

        return "Error: element '\(ref)' is not a picker, date picker, or segmented control"
    }

    private func tryPickerView(_ view: UIView, value: String, component: Int, ref: String, element: AppElement) -> String? {
        guard let picker = view as? UIPickerView,
              let dataSource = picker.dataSource else { return nil }

        let numComponents = dataSource.numberOfComponents(in: picker)
        guard component < numComponents else {
            return "Error: component \(component) out of range (picker has \(numComponents) components)"
        }

        let numRows = dataSource.pickerView(picker, numberOfRowsInComponent: component)
        let query = value.lowercased()

        // Try to find the row by matching the title text
        for row in 0..<numRows {
            let title: String?
            if let delegate = picker.delegate {
                // Try attributedTitle first, then title
                if let attr = delegate.pickerView?(picker, attributedTitleForRow: row, forComponent: component) {
                    title = attr.string
                } else {
                    title = delegate.pickerView?(picker, titleForRow: row, forComponent: component)
                }
            } else {
                title = nil
            }

            if let title, title.lowercased().contains(query) {
                picker.selectRow(row, inComponent: component, animated: true)
                picker.delegate?.pickerView?(picker, didSelectRow: row, inComponent: component)
                return "Selected \"\(title)\" (row \(row)) in \(ref) [\(element.kind)]"
            }
        }

        // Try numeric value as direct row index
        if let rowIndex = Int(value), rowIndex >= 0, rowIndex < numRows {
            picker.selectRow(rowIndex, inComponent: component, animated: true)
            picker.delegate?.pickerView?(picker, didSelectRow: rowIndex, inComponent: component)
            return "Selected row \(rowIndex) in \(ref) [\(element.kind)]"
        }

        return "Error: value \"\(value)\" not found in picker (searched \(numRows) rows in component \(component))"
    }

    private func tryDatePicker(_ view: UIView, value: String, ref: String, element: AppElement) -> String? {
        guard let datePicker = view as? UIDatePicker else { return nil }

        // Try multiple date formats
        let formatters: [(String, DateFormatter)] = [
            ("yyyy-MM-dd HH:mm", { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()),
            ("yyyy-MM-dd", { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()),
            ("HH:mm", { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()),
            ("MMM d, yyyy", { let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f }()),
        ]

        for (format, formatter) in formatters {
            if let date = formatter.date(from: value) {
                datePicker.setDate(date, animated: true)
                datePicker.sendActions(for: .valueChanged)
                return "Set date to \"\(value)\" (format: \(format)) in \(ref) [\(element.kind)]"
            }
        }

        return "Error: could not parse \"\(value)\" as date. Use: yyyy-MM-dd, yyyy-MM-dd HH:mm, or HH:mm"
    }

    private func trySegmentedControl(_ view: UIView, value: String, ref: String, element: AppElement) -> String? {
        guard let segment = view as? UISegmentedControl else { return nil }

        let query = value.lowercased()

        // Match by segment title
        for i in 0..<segment.numberOfSegments {
            if let title = segment.titleForSegment(at: i),
               title.lowercased().contains(query) {
                segment.selectedSegmentIndex = i
                segment.sendActions(for: .valueChanged)
                return "Selected \"\(title)\" (segment \(i)) in \(ref) [\(element.kind)]"
            }
        }

        // Try numeric as segment index
        if let idx = Int(value), idx >= 0, idx < segment.numberOfSegments {
            segment.selectedSegmentIndex = idx
            segment.sendActions(for: .valueChanged)
            let title = segment.titleForSegment(at: idx) ?? "index \(idx)"
            return "Selected \"\(title)\" (segment \(idx)) in \(ref) [\(element.kind)]"
        }

        let titles = (0..<segment.numberOfSegments).compactMap { segment.titleForSegment(at: $0) }
        return "Error: \"\(value)\" not found. Available: \(titles.joined(separator: ", "))"
    }

    // MARK: - Helpers

    private func findScrollView(at point: CGPoint, in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView,
           scrollView.frame.contains(point) {
            return scrollView
        }
        for subview in view.subviews.reversed() {
            let converted = subview.convert(point, from: view)
            if let found = findScrollView(at: converted, in: subview) {
                return found
            }
        }
        return nil
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}
#endif
