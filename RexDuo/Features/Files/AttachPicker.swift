import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Shows the system's pickers for the attach menu (Photos, Camera, Files) and hands back the chosen
/// files as staged copies, in the order they were chosen. Nothing is sent from here.
@MainActor
final class AttachPicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
    UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    /// What a picker produced: staged copies, and whether photos were to go untouched.
    var onPicked: (([StagedFile]) -> Void)?
    /// Turns a picked photo into what is sent (`ImagePrep`); the identity until set.
    var prepare: @Sendable (StagedFile, _ original: Bool) -> StagedFile = { f, _ in f }
    private var original = false

    static let maxPhotos = 20

    static var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func pickPhotos(over view: UIView, original: Bool) {
        self.original = original
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = Self.maxPhotos
        config.selection = .ordered
        config.filter = .any(of: [.images, .livePhotos, .videos])
        // The file as it is in the library (HEIC stays HEIC); `prepare` decides what is sent.
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, over: view)
    }

    func takePhoto(over view: UIView, original: Bool) {
        guard Self.cameraAvailable else { return }
        self.original = original
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = self
        present(picker, over: view)
    }

    func pickFiles(over view: UIView) {
        original = true
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, over: view)
    }

    private func present(_ vc: UIViewController, over view: UIView) {
        guard var top = view.window?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(vc, animated: true)
    }

    // MARK: Photos

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        let providers = results.map(\.itemProvider)
        let original = self.original
        let prepare = self.prepare
        Task { @MainActor in
            var files: [StagedFile] = []
            for p in providers {
                if let f = await Self.load(p) { files.append(await Self.prepared(f, original, prepare)) }
            }
            if files.count < providers.count {
                Notice.shared.show(files.isEmpty ? "Couldn't read the photos." : "Couldn't read some of the photos.")
            }
            if !files.isEmpty { self.onPicked?(files) }
        }
    }

    /// Copies the picked item's file in while the system's temporary copy still exists: it is only
    /// valid inside the callback. A Live Photo gives its still. Movies go as they are.
    private static func load(_ p: NSItemProvider) async -> StagedFile? {
        let type: UTType? = p.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? .image
            : p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? .movie
            : p.registeredContentTypes.first
        guard let type else { return nil }
        let suggested = p.suggestedName
        return await withCheckedContinuation { (c: CheckedContinuation<StagedFile?, Never>) in
            _ = p.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url else { return c.resume(returning: nil) }
                let ext = url.pathExtension
                let base = suggested.map { ext.isEmpty || $0.hasSuffix("." + ext) ? $0 : $0 + "." + ext } ?? url.lastPathComponent
                c.resume(returning: try? FileStaging.stage(copying: url, as: base))
            }
        }
    }

    private static func prepared(_ f: StagedFile, _ original: Bool,
                                 _ prepare: @escaping @Sendable (StagedFile, Bool) -> StagedFile) async -> StagedFile {
        await Task.detached(priority: .userInitiated) { prepare(f, original) }.value
    }

    // MARK: Camera

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85),
              let f = try? FileStaging.stage(data: data, as: UploadName.stamped("Photo", at: Date(), ext: "jpg")) else {
            Notice.shared.show("Couldn't keep the photo.")
            return
        }
        let original = self.original
        let prepare = self.prepare
        Task { @MainActor in self.onPicked?([await Self.prepared(f, original, prepare)]) }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    // MARK: Files

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Task { @MainActor in
            let files = await Task.detached(priority: .userInitiated) { () -> [StagedFile] in
                urls.compactMap { url in
                    // A copy the picker made for this app; the scope is for a provider that still
                    // asks for it.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? FileStaging.stage(moving: url, as: url.lastPathComponent)
                }
            }.value
            if files.count < urls.count { Notice.shared.show("Couldn't read some of the files.") }
            if !files.isEmpty { self.onPicked?(files) }
        }
    }
}
