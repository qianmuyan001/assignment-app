from ..schemas import AssignmentCreate
from .base import AssignmentSourceReader


class PlaceholderWebReader(AssignmentSourceReader):
    """Placeholder for future website assignment collection."""

    def __init__(self, source_url: str) -> None:
        self.source_url = source_url

    def read_assignments(self) -> list[AssignmentCreate]:
        # Future web readers will fetch webpage content from self.source_url.
        # After fetching, they should convert each found assignment into the
        # same AssignmentCreate format used by manual input and the API.
        #
        # AI parsing can be added later here or in a separate parser module.
        return []
