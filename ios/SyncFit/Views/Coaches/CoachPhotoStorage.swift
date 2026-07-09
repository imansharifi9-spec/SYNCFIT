import Foundation
import UIKit
import SwiftUI

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
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
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
