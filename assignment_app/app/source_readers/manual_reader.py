from typing import Any

from ..schemas import AssignmentCreate
from .base import AssignmentSourceReader


class ManualAssignmentReader(AssignmentSourceReader):
    """Convert manually entered assignment data into AssignmentCreate objects."""

    def __init__(self, assignments_data: list[dict[str, Any]]) -> None:
        self.assignments_data = assignments_data

    def read_assignments(self) -> list[AssignmentCreate]:
        return [AssignmentCreate(**assignment) for assignment in self.assignments_data]


def create_assignment_from_manual_input(data: dict[str, Any]) -> AssignmentCreate:
    return AssignmentCreate(**data)
