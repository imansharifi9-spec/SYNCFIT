import Foundation
import UIKit
import FirebaseAuth
import FirebaseStorage

enum ProgressPhotoStorage {
    static let localUserId = "local"

    /// Prefer the signed-in Auth UID so photos are scoped per account.
    static var currentUserId: String {
        if let uid = Auth.auth().currentUser?.uid,
           !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return uid
        }
        return localUserId
    }

    static func directory(for userId: String) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("ProgressPhotos", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func imageURL(fileName: String, userId: String) -> URL {
        directory(for: userId).appendingPathComponent(fileName)
    }

    static func storageObjectPath(userId: String, fileName: String) -> String {
        "users/\(userId)/progress_photos/\(fileName)"
    }

    static func saveJPEG(from image: UIImage, id: UUID, userId: String = localUserId) throws -> String {
        let fileName = "\(id.uuidString).jpg"
        let url = imageURL(fileName: fileName, userId: userId)
        guard let data = image.jpegData(compressionQuality: 0.82) else {
            throw ProgressPhotoError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
        return fileName
    }

    /// Uploads JPEG bytes to Firebase Storage and returns the download URL.
    static func uploadToFirebaseStorage(
        image: UIImage,
        userId: String,
        fileName: String
    ) async throws -> (downloadURL: String, storagePath: String) {
        guard FirebaseConfiguration.isConfigured else {
            throw ProgressPhotoError.firebaseUnavailable
        }
        guard let data = image.jpegData(compressionQuality: 0.82) else {
            throw ProgressPhotoError.encodingFailed
        }

        let storagePath = storageObjectPath(userId: userId, fileName: fileName)
        let ref = Storage.storage().reference().child(storagePath)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        print("[ProgressPhoto] Storage upload START \(storagePath) bytes=\(data.count)")
        do {
            _ = try await ref.putDataAsync(data, metadata: metadata)
            let url = try await ref.downloadURL()
            print("[ProgressPhoto] Storage upload OK \(storagePath)")
            return (url.absoluteString, storagePath)
        } catch {
            print("[ProgressPhoto] Storage upload FAILED \(storagePath): \(error)")
            throw error
        }
    }

    static func deleteRemote(storagePath: String?) async {
        guard let storagePath, !storagePath.isEmpty,
              FirebaseConfiguration.isConfigured else { return }
        let ref = Storage.storage().reference().child(storagePath)
        do {
            try await ref.delete()
            print("[ProgressPhoto] Storage delete OK \(storagePath)")
        } catch {
            print("[ProgressPhoto] Storage delete FAILED \(storagePath): \(error)")
        }
    }

    static func delete(fileName: String, userId: String) {
        let url = imageURL(fileName: fileName, userId: userId)
        try? FileManager.default.removeItem(at: url)
    }

    static func loadImage(fileName: String, userId: String) -> UIImage? {
        let url = imageURL(fileName: fileName, userId: userId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Loads from local cache first; falls back to downloadURL when present.
    static func loadImage(for entry: ProgressPhotoEntry) async -> UIImage? {
        if let local = loadImage(fileName: entry.fileName, userId: entry.userId) {
            return local
        }
        // Legacy photos may have been saved under the "local" folder.
        if entry.userId != localUserId,
           let legacy = loadImage(fileName: entry.fileName, userId: localUserId) {
            return legacy
        }
        guard let urlString = entry.downloadURL,
              let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                // Cache locally for next open.
                if let jpeg = image.jpegData(compressionQuality: 0.82) {
                    let localURL = imageURL(fileName: entry.fileName, userId: entry.userId)
                    try? jpeg.write(to: localURL, options: .atomic)
                }
                return image
            }
        } catch {
            print("[ProgressPhoto] Remote load FAILED \(urlString): \(error)")
        }
        return nil
    }
}

enum ProgressPhotoError: Error {
    case encodingFailed
    case firebaseUnavailable
}
