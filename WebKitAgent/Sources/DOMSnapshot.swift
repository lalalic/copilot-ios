import Foundation

/// JavaScript snippets for DOM interaction.
/// All scripts return JSON strings for consistent parsing.
enum DOMSnapshot {

    /// Scans the page for interactive elements, assigns data-wa-ref attributes,
    /// and returns a structured listing.
    static let snapshotScript = """
    (function() {
        // Remove old refs
        document.querySelectorAll('[data-wa-ref]').forEach(el => el.removeAttribute('data-wa-ref'));

        const isVisible = (el) => {
            const r = el.getBoundingClientRect();
            if (r.width === 0 && r.height === 0) return false;
            const s = window.getComputedStyle(el);
            return s.display !== 'none' && s.visibility !== 'hidden' && s.opacity !== '0';
        };

        const selectors = [
            'a[href]', 'button', 'input', 'textarea', 'select',
            '[role="button"]', '[role="link"]', '[role="tab"]',
            '[role="menuitem"]', '[role="checkbox"]', '[role="radio"]',
            '[role="switch"]', '[role="option"]', '[role="textbox"]',
            '[onclick]', '[tabindex]',
            'summary', 'label[for]', 'details',
            'video', 'audio'
        ];

        const elements = document.querySelectorAll(selectors.join(','));
        const refs = [];
        let idx = 0;

        elements.forEach(el => {
            if (!isVisible(el)) return;
            const ref = 'r' + idx;
            el.setAttribute('data-wa-ref', ref);

            const tag = el.tagName.toLowerCase();
            const type = el.type || '';
            const role = el.getAttribute('role') || '';
            const text = (el.textContent || '').trim().substring(0, 60).replace(/\\n/g, ' ');
            const value = el.value || '';
            const placeholder = el.placeholder || '';
            const href = el.href || '';
            const ariaLabel = el.getAttribute('aria-label') || '';
            const checked = el.checked;
            const disabled = el.disabled;

            let desc = ref + ' [' + tag;
            if (type) desc += ' type=' + type;
            if (role) desc += ' role=' + role;
            desc += ']';

            if (disabled) desc += ' (disabled)';
            if (checked !== undefined && checked !== null && tag === 'input') {
                desc += checked ? ' (checked)' : ' (unchecked)';
            }

            if (ariaLabel) desc += ' "' + ariaLabel + '"';
            else if (text && text.length <= 60) desc += ' "' + text + '"';

            if (placeholder) desc += ' placeholder="' + placeholder + '"';
            if (value && tag === 'input') desc += ' value="' + value.substring(0, 30) + '"';
            if (href && tag === 'a') {
                const shortHref = href.length > 60 ? href.substring(0, 57) + '...' : href;
                desc += ' → ' + shortHref;
            }

            refs.push(desc);
            idx++;
        });

        return JSON.stringify({
            title: document.title,
            url: location.href,
            count: idx,
            refs: refs
        });
    })()
    """

    /// Click an element by ref.
    static func clickScript(ref: String) -> String {
        let safeRef = ref.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (function() {
            const el = document.querySelector('[data-wa-ref="\(safeRef)"]');
            if (!el) return JSON.stringify({error: 'Element not found: \(safeRef)'});
            el.scrollIntoView({behavior: 'instant', block: 'center'});
            el.focus();
            el.click();
            const tag = el.tagName.toLowerCase();
            const text = (el.textContent || '').trim().substring(0, 40);
            return JSON.stringify({ok: true, tag: tag, text: text});
        })()
        """
    }

    /// Type text into an element by ref.
    static func typeScript(ref: String, text: String, clear: Bool) -> String {
        let safeRef = ref.replacingOccurrences(of: "\"", with: "\\\"")
        let safeText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function() {
            const el = document.querySelector('[data-wa-ref="\(safeRef)"]');
            if (!el) return JSON.stringify({error: 'Element not found: \(safeRef)'});
            el.scrollIntoView({behavior: 'instant', block: 'center'});
            el.focus();
            if (\(clear ? "true" : "false")) {
                el.value = '';
                el.dispatchEvent(new Event('input', {bubbles: true}));
            }
            el.value = "\(safeText)";
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return JSON.stringify({ok: true, value: el.value});
        })()
        """
    }
}
