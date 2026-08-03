from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, Integer, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from .database import Base


class Assignment(Base):
    __tablename__ = "assignments"
    __table_args__ = (
        CheckConstraint(
            "status IN ('not_started', 'in_progress', 'completed')",
            name="assignment_status_check",
        ),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    course_name: Mapped[str] = mapped_column(String(120), nullable=False, index=True)
    title: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    due_date: Mapped[datetime | None] = mapped_column(DateTime, nullable=True, index=True)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    link: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    status: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default="not_started",
        index=True,
    )
    source_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    source_type: Mapped[str | None] = mapped_column(String(80), nullable=True)
    source_file: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    source_url: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )
