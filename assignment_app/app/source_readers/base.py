from abc import ABC, abstractmethod
from typing import Any

from ..schemas import AssignmentCreate


class AssignmentSourceReader(ABC):
    """Base idea for anything that can collect assignments from one source."""

    @abstractmethod
    def read_assignments(self) -> list[AssignmentCreate | dict[str, Any]]:
        """Return assignments in the shared AssignmentCreate format."""
