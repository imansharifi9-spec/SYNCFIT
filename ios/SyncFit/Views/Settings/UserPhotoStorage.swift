import Foundation
import UIKit
import FirebaseAuth
import FirebaseStorage

/// Client profile avatar — mirrors coach profile photo storage (`coaches/{uid}/profile.jpg`).
enum UserPhotoStorage {
    static let profileFileName = "profile.jpg"

    static func directory(for userID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("UserPhotos", isDirectory: true)
            .appendingPathComponent(userID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func saveJPEG(from image: UIImage, fileName: String, userID: String) throws {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "UserPhotoStorage", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode profile JPEG."
            ])
        }
        let url = directory(for: userID).appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
    }

    static func loadImage(fileName: String, userID: String) -> UIImage? {
        let url = directory(for: userID).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func profileStoragePath(userAuthUID: String) -> String {
        "users/\(userAuthUID)/\(profileFileName)"
    }

    static func uploadProfilePhoto(image: UIImage, userAuthUID: String) async throws -> String {
        guard FirebaseConfiguration.isConfigured else {
            throw NSError(domain: "UserPhotoStorage", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Firebase is not configured."
            ])
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "UserPhotoStorage", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode profile JPEG."
            ])
        }

        let path = profileStoragePath(userAuthUID: userAuthUID)
        let ref = Storage.storage().reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        #if DEBUG
        print("[UserPhoto] Storage upload START \(path) bytes=\(data.count)")
        #endif
        do {
            _ = try await ref.putDataAsync(data, metadata: metadata)
            let url = try await ref.downloadURL()
            #if DEBUG
            print("[UserPhoto] Storage upload OK \(path)")
            #endif
            return url.absoluteString
        } catch {
            #if DEBUG
            print("[UserPhoto] Storage upload FAILED \(path): \(error)")
            #endif
            throw error
        }
    }

    static func loadProfileImage(
        userID: String,
        fileName: String?,
        photoURL: String?
    ) async -> UIImage? {
        let resolvedName = (fileName?.isEmpty == false) ? fileName! : profileFileName
        if let local = loadImage(fileName: resolvedName, userID: userID) {
            return local
        }
        guard let photoURL, let url = URL(string: photoURL), !photoURL.isEmpty else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return nil }
            try? saveJPEG(from: image, fileName: resolvedName, userID: userID)
            return image
        } catch {
            #if DEBUG
            print("[UserPhoto] Remote load FAILED \(photoURL): \(error)")
            #endif
            return nil
        }
    }
}
