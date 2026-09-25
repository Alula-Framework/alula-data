import AlulaCore
import Testing

@testable import AlulaDataCore

/// alula-data's keys were snake_case where Alula's are kebab-case. The
/// kebab-case spelling is documented now; the old one is still read.
@Suite("Configuration key spelling")
struct KeySpellingTests {
    @Test("the kebab-case key is read, the snake_case one still is, and kebab-case wins")
    func spellings() throws {
        let kebab = try DataSourceSettings.load(
            name: "primary", from: Configuration(values: [
                "datasource.primary.url": "postgres://h/db", "datasource.primary.pool-size": "3",
            ]))
        #expect(kebab.poolSize == 3)
        let snake = try DataSourceSettings.load(
            name: "primary", from: Configuration(values: [
                "datasource.primary.url": "postgres://h/db", "datasource.primary.pool_size": "4",
            ]))
        #expect(snake.poolSize == 4)
        let both = try DataSourceSettings.load(
            name: "primary", from: Configuration(values: [
                "datasource.primary.url": "postgres://h/db",
                "datasource.primary.pool-size": "5", "datasource.primary.pool_size": "6",
            ]))
        #expect(both.poolSize == 5)
    }
}
