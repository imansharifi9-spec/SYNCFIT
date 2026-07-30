import Foundation
import UIKit
import SwiftUI
import FirebaseAuth
import FirebaseStorage

struct CoachTransformationPhotoRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let fileName: String
    let date: Date

    init(id: UUID = UUID(), fileName: String, date: Date = .now) {
        self.id = id
        self.fileName = fileName
        self.date = date
    }
}

enum CoachPhotoStorage {
    static let profileFileName = "profile.jpg"

    static func directory(for coachID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("CoachPhotos", isDirectory: true)
            .appendingPathComponent(coachID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func transformationsDirectory(for coachID: UUID) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("CoachTransformations", isDirectory: true)
            .appendingPathComponent(coachID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func metadataURL(for coachID: UUID) -> URL {
        transformationsDirectory(for: coachID).appendingPathComponent("metadata.json")
    }

    static func loadTransformationRecords(for coachID: UUID) -> [CoachTransformationPhotoRecord] {
        let url = metadataURL(for: coachID)
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([CoachTransformationPhotoRecord].self, from: data) else {
            return []
        }
        return records.sorted { $0.date < $1.date }
    }

    private static func persistTransformationRecords(_ records: [CoachTransformationPhotoRecord], coachID: UUID) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: metadataURL(for: coachID), options: .atomic)
    }

    @discardableResult
    static func saveTransformationPhoto(from image: UIImage, coachID: UUID, date: Date = .now) throws -> CoachTransformationPhotoRecord {
        let record = CoachTransformationPhotoRecord(
            fileName: "transform_\(Int(date.timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).jpg",
            date: date
        )
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "CoachPhotoStorage", code: 1)
        }
        let url = transformationsDirectory(for: coachID).appendingPathComponent(record.fileName)
        try data.write(to: url, options: .atomic)

        var records = loadTransformationRecords(for: coachID)
        records.append(record)
        persistTransformationRecords(records, coachID: coachID)
        return record
    }

    static func loadTransformationImage(fileName: String, coachID: UUID) -> UIImage? {
        let url = transformationsDirectory(for: coachID).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func saveJPEG(from image: UIImage, fileName: String, coachID: UUID) throws {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "CoachPhotoStorage", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode profile JPEG."
            ])
        }
        let url = directory(for: coachID).appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
    }

    static func loadImage(fileName: String, coachID: UUID) -> UIImage? {
        let url = directory(for: coachID).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func delete(fileName: String, coachID: UUID) {
        let url = directory(for: coachID).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    /// Storage object path for the coach marketplace headshot.
    static func profileStoragePath(coachAuthUID: String) -> String {
        "coaches/\(coachAuthUID)/\(profileFileName)"
    }

    /// Uploads profile JPEG to Firebase Storage and returns a download URL.
    static func uploadProfilePhoto(image: UIImage, coachAuthUID: String) async throws -> String {
        guard FirebaseConfiguration.isConfigured else {
            throw NSError(domain: "CoachPhotoStorage", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Firebase is not configured."
            ])
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "CoachPhotoStorage", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode profile JPEG."
            ])
        }

        let path = profileStoragePath(coachAuthUID: coachAuthUID)
        let ref = Storage.storage().reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        print("[CoachPhoto] Storage upload START \(path) bytes=\(data.count)")
        do {
            _ = try await ref.putDataAsync(data, metadata: metadata)
            let url = try await ref.downloadURL()
            print("[CoachPhoto] Storage upload OK \(path)")
            return url.absoluteString
        } catch {
            print("[CoachPhoto] Storage upload FAILED \(path): \(error)")
            throw error
        }
    }

    /// Local cache first, then downloadURL. Caches remotely loaded bytes under coachID.
    static func loadProfileImage(
        coachID: UUID,
        fileName: String?,
        photoURL: String?
    ) async -> UIImage? {
        let resolvedName = (fileName?.isEmpty == false) ? fileName! : profileFileName
        if let local = loadImage(fileName: resolvedName, coachID: coachID) {
            return local
        }
        guard let photoURL, let url = URL(string: photoURL), !photoURL.isEmpty else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return nil }
            try? saveJPEG(from: image, fileName: resolvedName, coachID: coachID)
            return image
        } catch {
            print("[CoachPhoto] Remote load FAILED \(photoURL): \(error)")
            return nil
        }
    }
}

struct CoachCameraCapture: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CoachCameraCapture

        init(_ parent: CoachCameraCapture) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
