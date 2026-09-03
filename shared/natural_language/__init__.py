"""Natural-language schedule parsing for Assignment App.

This package turns a block of free-form text (for example a homework notice
pasted by the user) into a list of structured :class:`ParsedTask` candidates
that map cleanly onto SQLite schema v3. It is deliberately:

* platform-neutral (pure Python, no WinUI / no database),
* offline and deterministic (a ``now`` reference is always supplied, so
  "明天" / "下周三" resolve the same way in every test run),
* rule-based for the first milestone, with a parser interface that a later
  AI-backed parser can replace without changing callers or the contract.

Nothing here writes to the database. Callers must show an import preview and
let the user confirm or edit each candidate before a single SQLite
transaction creates the tasks.
"""

from .contract import ParsedSchedule, ParsedTask
from .parser import NaturalLanguageScheduleParser, parse_schedule

__all__ = [
    "ParsedSchedule",
    "ParsedTask",
    "NaturalLanguageScheduleParser",
    "parse_schedule",
]
