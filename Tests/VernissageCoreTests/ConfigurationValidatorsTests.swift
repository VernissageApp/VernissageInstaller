import Testing
@testable import VernissageCore

struct ConfigurationValidatorsTests {
    @Test
    func `Domain is normalized`() throws {
        let domain = try DomainValidator.validate("  Social.Example.COM.  ")

        #expect(domain == "social.example.com")
    }

    @Test(arguments: [
        "https://example.com",
        "localhost"
    ])
    func `Invalid domain is rejected`(_ domain: String) {
        #expect(throws: ConfigurationValidationError.self) {
            try DomainValidator.validate(domain)
        }
    }

    @Test
    func `Valid administrator email is accepted`() throws {
        let email = try AdministratorValidator.validateEmail("admin@example.com")

        #expect(email == "admin@example.com")
    }

    @Test(arguments: [
        "",
        "admin@.example.com",
        "admin..name@example.com"
    ])
    func `Invalid administrator email is rejected`(_ email: String) {
        #expect(throws: ConfigurationValidationError.self) {
            try AdministratorValidator.validateEmail(email)
        }
    }

    @Test
    func `Valid administrator username is accepted`() throws {
        let username = try AdministratorValidator.validateUsername("admin123")

        #expect(username == "admin123")
    }

    @Test
    func `Username with punctuation is rejected`() {
        #expect(throws: ConfigurationValidationError.self) {
            try AdministratorValidator.validateUsername("admin-user")
        }
    }

    @Test
    func `Password matches server rules and is redacted`() throws {
        let password = try AdministratorValidator.validatePassword("p@ssword")

        #expect(password.value == "p@ssword")
        #expect(password.description == "<redacted>")
        #expect(password.debugDescription == "<redacted>")
    }

    @Test(arguments: [
        "password",
        "p@ss"
    ])
    func `Invalid password is rejected`(_ password: String) {
        #expect(throws: ConfigurationValidationError.self) {
            try AdministratorValidator.validatePassword(password)
        }
    }
}
