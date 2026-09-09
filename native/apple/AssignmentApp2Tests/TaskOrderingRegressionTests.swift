import Foundation
import Testing
@testable import AssignmentApp2

struct TaskOrderingRegressionTests {
    private func task(_ id: Int64, _ title: String, created: TimeInterval, due: TimeInterval? = nil) -> Assignment {
        Assignment(id: id, courseName: "Course", title: title,
                   dueDate: due.map { Date(timeIntervalSince1970: $0) },
                   createdAt: Date(timeIntervalSince1970: created))
    }

    @Test func undatedTasksUseCreationThenPersistentID() {
        let tasks = [task(3, "A", created: 20), task(2, "Z", created: 10), task(1, "Y", created: 10)]
        #expect(TaskRules.sort(tasks, by: .dueDate).map(\.id) == [1, 2, 3])
    }

    @Test func titleEditingAndReloadPermutationDoNotMoveTasks() {
        var tasks = [task(3, "A", created: 20), task(1, "B", created: 10), task(2, "C", created: 10)]
        let expected: [Int64] = [1, 2, 3]
        #expect(TaskRules.sort(tasks, by: .dueDate).map(\.id) == expected)
        tasks[1].title = "ZZZ"
        #expect(TaskRules.sort(tasks.reversed(), by: .dueDate).map(\.id) == expected)
    }

    @Test func dueDatesComeFirstAndIdenticalDeadlinesHaveStableTies() {
        let tasks = [task(4, "A", created: 1), task(3, "Z", created: 3, due: 50),
                     task(2, "A", created: 3, due: 50), task(1, "B", created: 2, due: 20)]
        #expect(TaskRules.sort(tasks, by: .dueDate).map(\.id) == [1, 2, 3, 4])
    }

    @Test func continuousUndatedCreationAppendsWithinItsGroup() {
        var tasks = [task(1, "Z", created: 1)]
        for id in 2...12 {
            tasks.append(task(Int64(id), "A", created: TimeInterval(id)))
            #expect(TaskRules.sort(tasks.shuffled(), by: .dueDate).map(\.id) == Array(1...Int64(id)))
        }
    }
}
