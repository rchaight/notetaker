@testable import IndexKit
import Testing

@Test func moduleName() {
    #expect(IndexKitInfo.name == "IndexKit")
}

@Test func inMemoryDatabaseWorks() throws {
    #expect(try IndexKitInfo.databaseWorks())
}
