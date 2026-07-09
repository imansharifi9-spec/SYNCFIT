import Foundation

enum CoachMarketplaceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case muscleBuilding = "Muscle building"
    case fatLoss = "Fat loss"
    case powerlifting = "Powerlifting"
    case strength = "Strength"
    case weightLoss = "Weight loss"
    case online = "Online"
    case nearMe = "Near me"

    var id: String { rawValue }
}

struct CoachPortalProfile: Codable, Equatable {
    var id: UUID
    var coachUserID: String
    var name: String
    var specialties: [String]
    var about: String
    var ratePerMonth: Int
    var availability: CoachAvailability
    var location: String
    var photoFileName: String?
    var transformationPhotoFileNames: [String]
    var transformationPhotos: [CoachTransformationPhotoRecord]
    var testimonials: [CoachTestimonial]
    var isLive: Bool
    var isListed: Bool

    init(
        id: UUID = UUID(),
        coachUserID: String = "",
        name: String = "",
        specialties: [String] = [],
        about: String = "",
        ratePerMonth: Int = 75,
        availability: CoachAvailability = .online,
        location: String = "",
        photoFileName: String? = nil,
        transformationPhotoFileNames: [String] = [],
        transformationPhotos: [CoachTransformationPhotoRecord] = [],
        testimonials: [CoachTestimonial] = [],
        isLive: Bool = false,
        isListed: Bool = true
    ) {
        self.id = id
        self.coachUserID = coachUserID
        self.name = name
        self.specialties = specialties
        self.about = about
        self.ratePerMonth = ratePerMonth
        self.availability = availability
        self.location = location
        self.photoFileName = photoFileName
        self.transformationPhotoFileNames = transformationPhotoFileNames
        self.transformationPhotos = transformationPhotos
        self.testimonials = testimonials
        self.isLive = isLive
        self.isListed = isListed
    }

    var resolvedTransformationFileNames: [String] {
        if !transformationPhotos.isEmpty {
            return transformationPhotos.map(\.fileName)
        }
        return transformationPhotoFileNames
    }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !specialties.isEmpty
            && !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ratePerMonth > 0
    }

    func asMarketplaceProfile() -> CoachProfile {
        let specialty = specialties.first ?? "General fitness"
        return CoachProfile(
            id: id,
            name: name,
            specialty: specialty,
            pricePerMonth: ratePerMonth,
            isOnline: availability.supportsOnline,
            rating: 5.0,
            bio: CoachPlaceholderContent.sanitizedCoachBio(about),
            clientCount: 0,
            reviewCount: testimonials.count,
            availability: availability,
            location: location,
            specialties: specialties,
            reviews: testimonials.map {
                CoachReview(
                    clientName: $0.clientName,
                    text: CoachPlaceholderContent.sanitizedTestimonialQuote($0.quote),
                    rating: 5
                )
            },
            photoFileName: photoFileName,
            transformationPhotoFileNames: resolvedTransformationFileNames,
            isLive: isLive && isComplete,
            isListed: isListed,
            coachUserID: coachUserID.isEmpty ? nil : coachUserID
        )
    }
}

struct CoachTestimonial: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var clientName: String
    var quote: String

    init(id: UUID = UUID(), clientName: String = "", quote: String = "") {
        self.id = id
        self.clientName = clientName
        self.quote = quote
    }
}

enum CoachConnectionStatus: String, Codable {
    case active
    case inactive
}

struct CoachClientConnection: Identifiable, Codable, Hashable {
    var documentID: String
    var coachID: UUID
    var coachFirestoreID: String
    var coachName: String
    var clientUserID: String
    var clientName: String
    var connectedAt: Date
    var shareWorkouts: Bool
    var shareNutrition: Bool
    var shareProgress: Bool
    var status: CoachConnectionStatus
    var clientInitiatedContact: Bool

    var id: String { documentID }

    var isActive: Bool { status == .active }

    static func makeDocumentID(clientUserID: String, coachFirestoreID: String) -> String {
        [clientUserID, coachFirestoreID].sorted().joined(separator: "_")
    }

    init(
        coachID: UUID,
        coachFirestoreID: String,
        coachName: String,
        clientUserID: String,
        clientName: String,
        connectedAt: Date = .now,
        shareWorkouts: Bool = true,
        shareNutrition: Bool = false,
        shareProgress: Bool = false,
        status: CoachConnectionStatus = .active,
        clientInitiatedContact: Bool = false
    ) {
        self.documentID = Self.makeDocumentID(clientUserID: clientUserID, coachFirestoreID: coachFirestoreID)
        self.coachID = coachID
        self.coachFirestoreID = coachFirestoreID
        self.coachName = coachName
        self.clientUserID = clientUserID
        self.clientName = clientName
        self.connectedAt = connectedAt
        self.shareWorkouts = shareWorkouts
        self.shareNutrition = shareNutrition
        self.shareProgress = shareProgress
        self.status = status
        self.clientInitiatedContact = clientInitiatedContact
    }
}

struct CoachMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var conversationID: String
    var senderRole: CoachMessageSender
    var text: String
    var sentAt: Date

    init(
        id: UUID = UUID(),
        conversationID: String,
        senderRole: CoachMessageSender,
        text: String,
        sentAt: Date = .now
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderRole = senderRole
        self.text = text
        self.sentAt = sentAt
    }
}

enum CoachMessageSender: String, Codable {
    case coach
    case client
}

struct CoachConversation: Identifiable, Hashable {
    let id: String
    var clientName: String
    var lastMessage: String
    var lastMessageAt: Date
}

enum CoachPortalSpecialty: String, CaseIterable, Identifiable {
    case muscleBuilding = "Muscle building"
    case fatLoss = "Fat loss"
    case powerlifting = "Powerlifting"
    case strength = "Strength"
    case generalFitness = "General fitness"

    var id: String { rawValue }
}

enum CoachStyle {
    static let pageBackground = (red: 13.0 / 255, green: 13.0 / 255, blue: 13.0 / 255)
    static let cardBackground = (red: 17.0 / 255, green: 17.0 / 255, blue: 17.0 / 255)
    static let cardBorder = (red: 26.0 / 255, green: 26.0 / 255, blue: 26.0 / 255)
    static let chipInactiveBorder = (red: 42.0 / 255, green: 42.0 / 255, blue: 42.0 / 255)
    static let accentGreen = (red: 92.0 / 255, green: 219.0 / 255, blue: 110.0 / 255)
    static let chipActiveGreen = (red: 92.0 / 255, green: 219.0 / 255, blue: 110.0 / 255)
    static let verifiedBlue = (red: 106.0 / 255, green: 171.0 / 255, blue: 238.0 / 255)
    static let muted = (red: 136.0 / 255, green: 136.0 / 255, blue: 136.0 / 255)
    static let footerLink = (red: 68.0 / 255, green: 68.0 / 255, blue: 68.0 / 255)
    static let sectionLabel = (red: 85.0 / 255, green: 85.0 / 255, blue: 85.0 / 255)
    static let aiCardBackground = (red: 15.0 / 255, green: 26.0 / 255, blue: 15.0 / 255)
    static let aiCardBorder = (red: 30.0 / 255, green: 58.0 / 255, blue: 30.0 / 255)
}
