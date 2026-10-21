import Foundation
import CoreGraphics
import Testing
@testable import GlintCore

@Suite("SensitiveInfo")
struct SensitiveInfoTests {
    func cats(_ text: String, _ options: SensitiveInfoOptions = .all) -> [SensitiveCategory] {
        SensitiveInfoDetector(options: options).matches(in: text).map(\.category)
    }
    func texts(_ text: String, _ c: SensitiveCategory) -> [String] {
        SensitiveInfoDetector(options: .all).matches(in: text).filter { $0.category == c }.map(\.text)
    }

    @Test func luhn() {
        #expect(Luhn.isValid("4111 1111 1111 1111"))
        #expect(Luhn.isValid("5500-0000-0000-0004"))
        #expect(Luhn.isValid("378282246310005"))
        #expect(!Luhn.isValid("4111 1111 1111 1112"))
        #expect(!Luhn.isValid("1234"))
        #expect(!Luhn.isValid("abcd efgh ijkl mnop"))
    }

    @Test func creditCards() {
        #expect(texts("Card: 4111 1111 1111 1111 exp 12/30", .creditCard) == ["4111 1111 1111 1111"])
        #expect(texts("order 4111111111111112", .creditCard).isEmpty)
        #expect(texts("pay 5500-0000-0000-0004.", .creditCard) == ["5500-0000-0000-0004"])
    }

    @Test func email() {
        #expect(texts("write to jane.doe+x@mail.example.co.uk now", .email) == ["jane.doe+x@mail.example.co.uk"])
        #expect(texts("no at sign here", .email).isEmpty)
    }

    @Test func ipAddresses() {
        #expect(texts("host 192.168.1.10 and 10.0.0.255", .ipAddress) == ["192.168.1.10", "10.0.0.255"])
        #expect(texts("bad 999.1.1.1", .ipAddress).isEmpty)
        #expect(texts("v6 2001:db8::ff00:42:8329 end", .ipAddress) == ["2001:db8::ff00:42:8329"])
        #expect(texts("::1 loopback", .ipAddress) == ["::1"])
        #expect(texts("time 12:30:45 today", .ipAddress).isEmpty)
    }

    @Test func apiKeys() {
        #expect(texts("AWS AKIAIOSFODNN7EXAMPLE here", .apiKey) == ["AKIAIOSFODNN7EXAMPLE"])
        let gh = "ghp_" + String(repeating: "aB3dE6", count: 6)
        #expect(texts("token \(gh)", .apiKey) == [gh])
        #expect(texts("xoxb-123456789012-abcdefghijkl", .apiKey).count == 1)
        let stripe = "sk_live_" + "4eC39HqLyjWDarjtT1zdp7dc"
        #expect(texts("key=\(stripe)", .apiKey) == [stripe])
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N"
        #expect(texts("Bearer \(jwt)", .apiKey) == [jwt])
        #expect(texts("secret 9fA3kQ7zLm2XvB8nR4tY1wC6pD0sHj5E", .apiKey).count == 1) // high entropy
        #expect(texts("internationalizationlocalizationconfiguration", .apiKey).isEmpty) // no digits
        #expect(texts("a normal sentence with words", .apiKey).isEmpty)
    }

    @Test func ssnPhoneMacUrl() {
        #expect(texts("SSN 123-45-6789", .ssn) == ["123-45-6789"])
        #expect(texts("SSN 000-12-3456", .ssn).isEmpty)
        #expect(texts("call +1 (415) 555-2671 today", .phone) == ["+1 (415) 555-2671"])
        #expect(texts("call 020 7946 0958", .phone) == ["020 7946 0958"])
        #expect(texts("build 20240131", .phone).isEmpty)
        #expect(texts("date 2024-01-31", .phone).isEmpty)
        #expect(texts("mac 3C:22:FB:01:AB:9F", .macAddress) == ["3C:22:FB:01:AB:9F"])
        #expect(texts("see https://example.com/a?b=1, ok", .url) == ["https://example.com/a?b=1"])
    }

    @Test func categoriesAreToggleable() {
        let text = "mail a@b.io host 10.1.2.3"
        #expect(cats(text, SensitiveInfoOptions(categories: [.email])) == [.email])
        #expect(cats(text, SensitiveInfoOptions(categories: [.ipAddress])) == [.ipAddress])
        #expect(cats(text, SensitiveInfoOptions(categories: [])).isEmpty)
    }

    @Test func customWords() {
        let o = SensitiveInfoOptions(categories: [.custom], customWords: ["Project Falcon", "acme"])
        let m = SensitiveInfoDetector(options: o).matches(in: "Notes on project falcon and ACME corp, Acme.")
        #expect(m.map(\.text) == ["project falcon", "ACME", "Acme"])
        var cs = o; cs.caseSensitive = true
        #expect(SensitiveInfoDetector(options: cs).matches(in: "project falcon acme").map(\.text) == ["acme"])
    }

    @Test func noOverlapBetweenCategories() {
        let ms = SensitiveInfoDetector(options: .all).matches(in: "token 4111111111111111 at 192.168.0.1")
        #expect(ms.map(\.category) == [.creditCard, .ipAddress])
    }

    @Test func findingsMapToRects() {
        let line = RecognizedLine(text: "mail jane@x.io now", box: CGRect(x: 100, y: 50, width: 180, height: 20))
        let f = SensitiveInfoDetector(options: .all).findings(in: [line])
        #expect(f.count == 1)
        #expect(abs(f[0].rect.minX - 150) < 0.001)
        #expect(abs(f[0].rect.width - 90) < 0.001)

        let words = [RecognizedWord(text: "mail", range: NSRange(location: 0, length: 4), box: CGRect(x: 10, y: 0, width: 40, height: 10)),
                     RecognizedWord(text: "jane@x.io", range: NSRange(location: 5, length: 9), box: CGRect(x: 60, y: 0, width: 90, height: 10)),
                     RecognizedWord(text: "now", range: NSRange(location: 15, length: 3), box: CGRect(x: 160, y: 0, width: 30, height: 10))]
        let wl = RecognizedLine(text: "mail jane@x.io now", box: CGRect(x: 10, y: 0, width: 180, height: 10), words: words)
        let wf = SensitiveInfoDetector(options: .all).findings(in: [wl])
        #expect(wf[0].rect == CGRect(x: 60, y: 0, width: 90, height: 10))
    }

    @Test func autoRedactAnnotations() {
        let line = RecognizedLine(text: "card 4111 1111 1111 1111", box: CGRect(x: 10, y: 10, width: 240, height: 20))
        let opts = AutoRedactOptions(detector: SensitiveInfoOptions(categories: [.creditCard]), style: .blur, padding: 2)
        let a = AutoRedact.annotations(for: [line], options: opts, imageSize: CGSize(width: 300, height: 100))
        #expect(a.count == 1)
        if case .blur(let r) = a[0].kind { #expect(r.width > 0 && r.minX >= 8) } else { Issue.record("expected blur") }
        let solid = AutoRedact.annotations(for: [line], options: AutoRedactOptions(detector: opts.detector))
        if case .redact = solid[0].kind {} else { Issue.record("expected redact") }
    }

    @Test func recognizesRenderedText() async throws {
        let image = TestImages.text("Contact jane@example.com today", size: 44)
        let lines: [RecognizedLine]
        do { lines = try await TextRecognizer.recognize(in: image) }
        catch { print("Vision unavailable headlessly: \(error)"); return }
        guard !lines.isEmpty else { print("Vision returned no text headlessly"); return }
        let joined = lines.map(\.text).joined(separator: " ")
        #expect(joined.lowercased().contains("contact"))
        let findings = SensitiveInfoDetector(options: SensitiveInfoOptions(categories: [.email])).findings(in: lines)
        #expect(findings.count == 1)
        if let f = findings.first {
            #expect(f.rect.minX > 100 && f.rect.maxX < 900 && f.rect.minY < 100) // lies on the text row
        }
        let ann = await AutoRedact.run(image, options: AutoRedactOptions(detector: SensitiveInfoOptions(categories: [.email])))
        #expect(ann.count == 1)
    }
}
