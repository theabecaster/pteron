import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Shows the system's pickers for the attach menu (Photos, Camera, Files) and hands back the chosen
/// files as staged copies, in the order they were chosen. Nothing is sent from here.
@MainActor
final class AttachPicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
    UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    /// What a picker produced: staged copies, prepared. Files from Files go as they are.
    var onPicked: (([ImagePrep.Result]) -> Void)?
    /// What the Files picker produced where folders may be picked: the items where they are,
    /// each with its security scope started; the receiver releases them (`Outgoing.release`).
    var onPickedInPlace: (([Outgoing]) -> Void)?
    /// The open Files picker lets folders be picked and reads items in place.
    private var inPlace = false
    /// Turns a picked photo into what is sent (`ImagePrep`); the identity until set.
    var prepare: @Sendable (StagedFile) -> ImagePrep.Result = { .ready($0) }

    static let maxPhotos = 20

    static var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func pickPhotos(over view: UIView) {
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

    func takePhoto(over view: UIView) {
        guard Self.cameraAvailable else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = self
        present(picker, over: view)
    }

    /// `folders`: the pane's computer takes folders. The picker then offers folders beside files
    /// and gives the items where they are, under their security scope, so a large folder is read
    /// as it is sent and never copied first. Otherwise it gives copies of files, as before.
    func pickFiles(over view: UIView, folders: Bool = false) {
        inPlace = folders
        let picker = folders
            ? UIDocumentPickerViewController(forOpeningContentTypes: [.item, .folder], asCopy: false)
            : UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
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
        let prepare = self.prepare
        Task { @MainActor in
            var files: [ImagePrep.Result] = []
            for p in providers {
                if let f = await Self.load(p) { files.append(await Self.prepared(f, prepare)) }
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

    private static func prepared(_ f: StagedFile,
                                 _ prepare: @escaping @Sendable (StagedFile) -> ImagePrep.Result) async -> ImagePrep.Result {
        await Task.detached(priority: .userInitiated) { prepare(f) }.value
    }

    // MARK: Camera

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage else {
            Notice.shared.show("Couldn't keep the photo.")
            return
        }
        let name = UploadName.stamped("Photo", at: Date(), ext: "jpg")
        let prepare = self.prepare
        Task { @MainActor in
            // Encoded off the main thread, at full quality: `prepare` scales it and encodes it
            // once more, so the photo is compressed only once at the quality that is sent.
            let result = await Task.detached(priority: .userInitiated) { () -> ImagePrep.Result? in
                guard let data = image.jpegData(compressionQuality: 1),
                      let f = try? FileStaging.stage(data: data, as: name) else { return nil }
                return prepare(f)
            }.value
            guard let result else { return Notice.shared.show("Couldn't keep the photo.") }
            self.onPicked?([result])
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    // MARK: Files

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if inPlace {
            let items = urls.map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return Outgoing(url: url, name: UploadName.sanitize(url.lastPathComponent, fallback: folder ? "Folder" : "File"),
                                isFolder: folder, owned: false, scoped: scoped)
            }
            if !items.isEmpty { onPickedInPlace?(items) }
            return
        }
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
            if !files.isEmpty { self.onPicked?(files.map { .ready($0) }) }
        }
    }
}
