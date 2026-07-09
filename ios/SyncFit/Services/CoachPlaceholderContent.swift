import Foundation

/// Replaces dev/test placeholder copy in coach profiles and messages with realistic defaults.
enum CoachPlaceholderContent {
    static let defaultCoachBio =
        "5+ years coaching muscle building and strength programs. I focus on sustainable progressive overload and building lifting confidence for lifters at any level."

    static let defaultMessagePreview =
        "Hey! Just reviewed your leg day, great progress on the squat PR."

    static let defaultTestimonialQuote =
        "Clear programming and great check-ins. I added 20 lbs to my squat in two months."

    private static let inappropriateSubstrings = [
        "gooner",
        "booty",
        "latina",
        "calm down g",
        "big booty",
        "certified gooner"
    ]

    static func sanitizedCoachBio(_ bio: String) -> String {
        guard isInappropriateCoachBio(bio) else { return bio }
        return defaultCoachBio
    }

    static func sanitizedMessage(_ text: String) -> String {
        guard isInappropriateMessage(text) else { return text }
        return defaultMessagePreview
    }

    static func sanitizedTestimonialQuote(_ quote: String) -> String {
        guard isInappropriateTestimonial(quote) else { return quote }
        return defaultTestimonialQuote
    }

    static func isInappropriateCoachBio(_ bio: String) -> Bool {
        let normalized = normalize(bio)
        guard !normalized.isEmpty else { return false }
        return inappropriateSubstrings.contains { normalized.contains($0) }
    }

    static func isInappropriateMessage(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }
        if inappropriateSubstrings.contains(where: { normalized.contains($0) }) {
            return true
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = trimmed.filter(\.isLetter)
        guard !letters.isEmpty else { return false }

        let isAllCaps = trimmed == trimmed.uppercased()
        let isShortShout = trimmed.count <= 32
        return isAllCaps && isShortShout
    }

    static func isInappropriateTestimonial(_ quote: String) -> Bool {
        let normalized = normalize(quote)
        guard !normalized.isEmpty else { return false }
        return inappropriateSubstrings.contains { normalized.contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension CoachPortalProfile {
    @discardableResult
    mutating func sanitizePlaceholderContent() -> Bool {
        var changed = false

        let sanitizedBio = CoachPlaceholderContent.sanitizedCoachBio(about)
        if sanitizedBio != about {
            about = sanitizedBio
            changed = true
        }

        for index in testimonials.indices {
            let sanitizedQuote = CoachPlaceholderContent.sanitizedTestimonialQuote(testimonials[index].quote)
            if sanitizedQuote != testimonials[index].quote {
                testimonials[index].quote = sanitizedQuote
                changed = true
            }
        }

        return changed
    }
}

extension CoachProfile {
    func sanitizedForDisplay() -> CoachProfile {
        var copy = self

        copy.bio = CoachPlaceholderContent.sanitizedCoachBio(copy.bio)
        copy.reviews = copy.reviews.map { review in
            var sanitizedReview = review
            sanitizedReview.text = CoachPlaceholderContent.sanitizedTestimonialQuote(review.text)
            return sanitizedReview
        }

        return copy
    }
}
