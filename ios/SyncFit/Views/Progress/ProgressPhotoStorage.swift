import Foundation
import UIKit

enum ProgressPhotoStorage {
    static let localUserId = "local"

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

    static func saveJPEG(from image: UIImage, id: UUID, userId: String = localUserId) throws -> String {
        let fileName = "\(id.uuidString).jpg"
        let url = imageURL(fileName: fileName, userId: userId)
        guard let data = image.jpegData(compressionQuality: 0.82) else {
            throw ProgressPhotoError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
        return fileName
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
}

enum ProgressPhotoError: Error {
    case encodingFailed
}
