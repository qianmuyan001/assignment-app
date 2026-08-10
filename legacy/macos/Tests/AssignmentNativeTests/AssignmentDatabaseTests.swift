import Foundation
import XCTest
@testable import AssignmentNative


final class AssignmentDatabaseTests: XCTestCase {
    func testCandidateImportSkipsExactDuplicateAndSupportsStatusAndDelete() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssignmentNativeTests-\(UUID().uuidString)")
        let databaseURL = directory.appendingPathComponent("assignments.db")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let database = try AssignmentDatabase(url: databaseURL)
        let candidate = AssignmentCandidate(
            courseName: "CSE 122",
            title: "Project 2",
            dueDate: "2026-07-30",
            dueTime: "23:59",
            description: "Implement dictionary pruning.",
            sourceName: "Canvas",
            sourceURL: "https://canvas.example/courses/122/assignments/2",
            confidence: "high",
            warnings: []
        )

        XCTAssertEqual(
            try database.insertCandidates(
                [candidate],
                fallbackCourse: "",
                sourceName: "Canvas",
                sourceURL: "https://canvas.example"
            ),
            1
        )
        XCTAssertEqual(
            try database.insertCandidates(
                [candidate],
                fallbackCourse: "",
                sourceName: "Canvas",
                sourceURL: "https://canvas.example"
            ),
            0
        )

        var assignments = try database.fetchAssignments()
        XCTAssertEqual(assignments.count, 1)
        XCTAssertEqual(assignments[0].status, .notStarted)
        XCTAssertEqual(assignments[0].sourceType, "secure_web")

        try database.updateStatus(id: assignments[0].id, status: .completed)
        assignments = try database.fetchAssignments()
        XCTAssertEqual(assignments[0].status, .completed)

        try database.delete(id: assignments[0].id)
        XCTAssertTrue(try database.fetchAssignments().isEmpty)
    }

    func testLocalAIEndpointRejectsRemoteHosts() async {
        let parser = LocalAIParser()
        do {
            try await parser.updateEndpoint("https://example.com")
            XCTFail("A non-loopback AI endpoint should be rejected.")
        } catch LocalAIError.invalidEndpoint {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCredentialOriginIncludesNonDefaultPortAndRejectsHTTP() throws {
        XCTAssertEqual(
            try CredentialOrigin.value(
                for: XCTUnwrap(URL(string: "https://School.Example/login"))
            ),
            "https://school.example"
        )
        XCTAssertEqual(
            try CredentialOrigin.value(
                for: XCTUnwrap(URL(string: "https://school.example:8443/login"))
            ),
            "https://school.example:8443"
        )
        XCTAssertThrowsError(
            try CredentialOrigin.value(
                for: XCTUnwrap(URL(string: "http://school.example/login"))
            )
        )
    }
}
