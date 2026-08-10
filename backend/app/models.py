from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, Integer, String, Text, case, func
from sqlalchemy.ext.hybrid import hybrid_property
from sqlalchemy.orm import Mapped, mapped_column

from .database import Base


class Assignment(Base):
    __tablename__ = "assignments"
    __table_args__ = (
        CheckConstraint(
            "status IN ('not_started', 'in_progress', 'completed')",
            name="assignment_status_check",
        ),
        CheckConstraint(
            "priority IN ('low', 'medium', 'high')",
            name="assignment_priority_check",
        ),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    course_name: Mapped[str] = mapped_column(String(120), nullable=False, index=True)
    title: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    due_date: Mapped[datetime | None] = mapped_column(DateTime, nullable=True, index=True)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    link: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    _status: Mapped[str] = mapped_column(
        "status",
        String(20),
        nullable=False,
        default="not_started",
        index=True,
    )
    priority: Mapped[str] = mapped_column(
        String(10),
        nullable=False,
        default="medium",
        index=True,
    )
    source_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    source_type: Mapped[str | None] = mapped_column(String(80), nullable=True)
    source_file: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    source_url: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),  # pylint: disable=not-callable
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),  # pylint: disable=not-callable
        onupdate=func.now(),  # pylint: disable=not-callable
        nullable=False,
    )

    @hybrid_property
    def status(self) -> str:
        """Expose canonical v2 UI values while retaining legacy DB values."""

        return {
            "not_started": "todo",
            "in_progress": "in_progress",
            "completed": "done",
        }.get(self._status, self._status)

    @status.inplace.setter
    def _set_status(self, value: str) -> None:
        try:
            self._status = {
                "todo": "not_started",
                "not_started": "not_started",
                "in_progress": "in_progress",
                "done": "completed",
                "completed": "completed",
            }[value]
        except KeyError as exc:
            raise ValueError(f"Unsupported assignment status: {value!r}") from exc

    @status.inplace.expression
    @classmethod
    def _status_expression(cls):
        return case(
            (cls._status == "not_started", "todo"),
            (cls._status == "completed", "done"),
            else_=cls._status,
        )
