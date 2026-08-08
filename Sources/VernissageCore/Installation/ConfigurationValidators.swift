import Foundation

enum ConfigurationValidationError: LocalizedError, Equatable {
    case invalidDomain(String)
    case invalidAdministratorName(String)
    case invalidEmail(String)
    case invalidUsername(String)
    case invalidPassword(String)
    case passwordConfirmationMismatch
    case inputEnded(String)

    var errorDescription: String? {
        switch self {
        case .invalidDomain(let reason),
             .invalidAdministratorName(let reason),
             .invalidEmail(let reason),
             .invalidUsername(let reason),
             .invalidPassword(let reason):
            return reason
        case .passwordConfirmationMismatch:
            return "The passwords do not match."
        case .inputEnded(let field):
            return "No value was provided for the required field: \(field)."
        }
    }
}

enum DomainValidator {
    static func validate(_ input: String) throws -> String {
        var domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if domain.last == "." {
            domain.removeLast()
        }

        guard !domain.isEmpty else {
            throw ConfigurationValidationError.invalidDomain("The instance domain is required.")
        }

        guard domain.count <= 253 else {
            throw ConfigurationValidationError.invalidDomain("The domain cannot be longer than 253 characters.")
        }

        guard !domain.contains("://"),
              !domain.contains("/"),
              !domain.contains(":"),
              !domain.contains("@") else {
            throw ConfigurationValidationError.invalidDomain(
                "Enter only a domain, for example social.example.com, without a scheme, path, port, or @."
            )
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            throw ConfigurationValidationError.invalidDomain("Enter a fully qualified domain, for example social.example.com.")
        }

        for label in labels {
            guard !label.isEmpty, label.count <= 63 else {
                throw ConfigurationValidationError.invalidDomain("Every domain label must contain between 1 and 63 characters.")
            }

            guard label.first != "-", label.last != "-" else {
                throw ConfigurationValidationError.invalidDomain("A domain label cannot begin or end with a hyphen.")
            }

            guard label.utf8.allSatisfy({ byte in
                (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
            }) else {
                throw ConfigurationValidationError.invalidDomain(
                    "The domain may contain only ASCII letters, digits, hyphens, and dots. Use its Punycode form for an internationalized domain."
                )
            }
        }

        guard labels.last?.contains(where: { $0.isLetter }) == true else {
            throw ConfigurationValidationError.invalidDomain("The top-level domain must contain a letter.")
        }

        return domain
    }
}

enum AdministratorValidator {
    static func validateName(_ input: String?) throws -> String? {
        guard let value = normalizedOptional(input) else {
            return nil
        }

        guard value.count <= 100 else {
            throw ConfigurationValidationError.invalidAdministratorName(
                "The administrator name cannot be longer than 100 characters."
            )
        }

        return value
    }

    static func validateEmail(_ input: String) throws -> String {
        let email = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)

        guard email.count <= 254,
              parts.count == 2,
              (1...64).contains(parts[0].count),
              parts[0].first != ".",
              parts[0].last != ".",
              !parts[0].contains(".."),
              parts[0].utf8.allSatisfy(isValidEmailLocalPartByte) else {
            throw ConfigurationValidationError.invalidEmail("Enter a valid administrator email address.")
        }

        do {
            _ = try DomainValidator.validate(String(parts[1]))
        } catch {
            throw ConfigurationValidationError.invalidEmail("Enter a valid administrator email address.")
        }

        return email
    }

    static func validateUsername(_ input: String) throws -> String {
        let username = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (1...50).contains(username.count),
              username.utf8.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
              }) else {
            throw ConfigurationValidationError.invalidUsername(
                "The username must contain 1–50 ASCII letters or digits, without spaces or punctuation."
            )
        }

        return username
    }

    static func validatePassword(_ input: String) throws -> Secret {
        guard (8...32).contains(input.count) else {
            throw ConfigurationValidationError.invalidPassword("The password must contain between 8 and 32 characters.")
        }

        let hasLetter = input.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        let hasDigit = input.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasSymbol = input.unicodeScalars.contains {
            !CharacterSet.letters.contains($0) &&
            !CharacterSet.decimalDigits.contains($0) &&
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }

        guard hasLetter, hasDigit || hasSymbol else {
            throw ConfigurationValidationError.invalidPassword(
                "The password must contain at least one letter and at least one number or symbol."
            )
        }

        return Secret(value: input)
    }

    private static func normalizedOptional(_ input: String?) -> String? {
        let value = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func isValidEmailLocalPartByte(_ byte: UInt8) -> Bool {
        let isLetterOrDigit = (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) ||
            (byte >= 48 && byte <= 57)
        let allowedPunctuation: Set<UInt8> = [
            33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 47, 61, 63,
            94, 95, 96, 123, 124, 125, 126
        ]

        return isLetterOrDigit || allowedPunctuation.contains(byte)
    }
}
