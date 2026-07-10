import Testing
@testable import IndexKit

@Test func moduleName() {
    #expect(IndexKitInfo.name == "IndexKit")
}

@Test func inMemoryDatabaseWorks() throws {
    #expect(try IndexKitInfo.databaseWorks())
}
