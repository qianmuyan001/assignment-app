import json
from datetime import datetime, timezone
from pathlib import Path

from .schemas import AssignmentCreate, AssignmentRead, AssignmentStatusUpdate, AssignmentUpdate


DATA_FILE = Path(__file__).resolve().parents[1] / "data" / "assignments.json"


def _ensure_data_file_exists() -> None:
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)

    if not DATA_FILE.exists():
        DATA_FILE.write_text("[]\n", encoding="utf-8")


def load_assignments() -> list[dict]:
    _ensure_data_file_exists()

    with DATA_FILE.open("r", encoding="utf-8") as file:
        data = json.load(file)

    if not isinstance(data, list):
        return []

    return data


def save_assignments(assignments: list[dict]) -> None:
    _ensure_data_file_exists()

    with DATA_FILE.open("w", encoding="utf-8") as file:
        json.dump(assignments, file, indent=2)
        file.write("\n")


def get_all_assignments() -> list[AssignmentRead]:
    assignments = load_assignments()
    return [AssignmentRead(**assignment) for assignment in assignments]


def get_assignment_by_id(assignment_id: int) -> AssignmentRead | None:
    assignments = load_assignments()

    for assignment in assignments:
        if assignment.get("id") == assignment_id:
            return AssignmentRead(**assignment)

    return None


def create_assignment(assignment_create: AssignmentCreate) -> AssignmentRead:
    assignments = load_assignments()
    now = datetime.now(timezone.utc)

    assignment = AssignmentRead(
        id=_get_next_id(assignments),
        created_at=now,
        updated_at=now,
        **assignment_create.model_dump(),
    )

    assignments.append(assignment.model_dump(mode="json"))
    save_assignments(assignments)

    return assignment


def update_assignment(
    assignment_id: int,
    assignment_update: AssignmentUpdate,
) -> AssignmentRead | None:
    assignments = load_assignments()

    for index, saved_assignment in enumerate(assignments):
        if saved_assignment.get("id") == assignment_id:
            current_assignment = AssignmentRead(**saved_assignment)
            update_data = assignment_update.model_dump(exclude_unset=True)
            updated_data = current_assignment.model_dump()
            updated_data.update(update_data)
            updated_data["updated_at"] = datetime.now(timezone.utc)

            updated_assignment = AssignmentRead(**updated_data)

            assignments[index] = updated_assignment.model_dump(mode="json")
            save_assignments(assignments)

            return updated_assignment

    return None


def update_assignment_status(
    assignment_id: int,
    status_update: AssignmentStatusUpdate,
) -> AssignmentRead | None:
    assignment_update = AssignmentUpdate(status=status_update.status)
    return update_assignment(assignment_id, assignment_update)


def delete_assignment(assignment_id: int) -> AssignmentRead | None:
    assignments = load_assignments()

    for index, assignment in enumerate(assignments):
        if assignment.get("id") == assignment_id:
            deleted_assignment = AssignmentRead(**assignment)
            del assignments[index]
            save_assignments(assignments)
            return deleted_assignment

    return None


def _get_next_id(assignments: list[dict]) -> int:
    if not assignments:
        return 1

    return max(assignment.get("id", 0) for assignment in assignments) + 1
