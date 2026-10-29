import AppKit
import UniformTypeIdentifiers

/// Shared helpers for exporting a captured image: copying it to the clipboard
/// or saving it to a PNG file, mirroring ZoomIt's Ctrl+C / Ctrl+S behaviour.
@MainActor
enum ImageExporter {
    /// Copies the image to the general pasteboard as PNG and TIFF so it can be
    /// pasted into the widest range of apps.
    static func copyToPasteboard(
        _ image: CGImage,
        transcript: String = "",
        pasteboard: NSPasteboard = .general
    ) {
        guard let item = makePasteboardItem(image: image, transcript: transcript) else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Builds one pasteboard item with image fallbacks. When the transcript is
    /// non-empty, the same item also carries rich RTFD/HTML representations
    /// containing both the image and text plus a plain-text fallback.
    static func makePasteboardItem(image: CGImage, transcript: String) -> NSPasteboardItem? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }

        guard !transcript.isEmpty else { return item }

        let attachment = NSTextAttachment(data: png, ofType: UTType.png.identifier)
        let richText = NSMutableAttributedString(
            attributedString: NSAttributedString(attachment: attachment)
        )
        richText.append(NSAttributedString(string: "\n\(transcript)"))
        let fullRange = NSRange(location: 0, length: richText.length)
        if let rtfd = try? richText.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        ) {
            item.setData(rtfd, forType: .rtfd)
        }

        let escapedTranscript = escapeHTML(transcript).replacingOccurrences(of: "\n", with: "<br>")
        let html = """
        <div><img alt="Snip" src="data:image/png;base64,\(png.base64EncodedString())"><p>\(escapedTranscript)</p></div>
        """
        item.setString(html, forType: .html)
        item.setString(transcript, forType: .string)
        return item
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Saves the image according to the user's snip preferences: optionally
    /// copies it to the clipboard as well, then either writes it directly to the
    /// configured directory or presents a Save dialog. `onWillShowSaveDialog` is
    /// invoked only when the Save dialog is about to appear, so callers can
    /// prepare their UI (e.g. lower an overlay window).
    static func saveImage(
        _ image: CGImage,
        settings: AppSettings,
        userSelectedResourceAccess: UserSelectedResourceAccess,
        onWillShowSaveDialog: (() -> Void)? = nil
    ) {
        if settings.copySnipToClipboardOnSave {
            copyToPasteboard(image)
        }
        if settings.saveSnipToDirectory {
            if writeToDirectory(
                image,
                directoryPath: settings.snipSaveDirectory,
                userSelectedResourceAccess: userSelectedResourceAccess
            ) {
                return
            }
        }
        onWillShowSaveDialog?()
        presentSavePanel(for: image)
    }

    /// Presents a Save dialog defaulting to a timestamped PNG name and writes
    /// the image as PNG.
    static func presentSavePanel(for image: CGImage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// Writes the image as a timestamped PNG into `directoryPath` (or the user's
    /// Documents folder when it is empty), creating the directory if needed.
    @discardableResult
    static func writeToDirectory(
        _ image: CGImage,
        directoryPath: String,
        userSelectedResourceAccess: UserSelectedResourceAccess
    ) -> Bool {
        do {
            try userSelectedResourceAccess.withAccess(
                to: .snipDirectory,
                legacyPath: resolvedSaveDirectory(directoryPath).path
            ) { directoryURL in
                let fileManager = FileManager.default
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

                let url = directoryURL.appendingPathComponent(suggestedFilename())
                let rep = NSBitmapImageRep(cgImage: image)
                guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: url)
            }
            return true
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// The directory used when saving directly: the configured folder, or the
    /// user's Documents folder when unset.
    static func resolvedSaveDirectory(_ directoryPath: String) -> URL {
        let trimmed = directoryPath.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return defaultSaveDirectory()
        }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The default save location shown in Settings and used when no directory is
    /// configured: the user's Documents folder.
    static func defaultSaveDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// "ZoomIt YYYY-MM-DD HHMMSS.png", matching ZoomIt's unique-name scheme.
    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "ZoomIt \(formatter.string(from: Date())).png"
    }
}
