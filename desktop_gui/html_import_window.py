from __future__ import annotations

from tkinter import messagebox
from typing import Any, Callable

import customtkinter as ctk

try:
    from . import api_client, theme
    from .components import clean_text, parse_due_datetime
except ImportError:
    import api_client
    import theme
    from components import clean_text, parse_due_datetime


class PendingImportWindow(ctk.CTkToplevel):
    def __init__(
        self,
        master: ctk.CTkBaseClass,
        assignments: list[dict[str, Any]],
        on_imported: Callable[[], None] | None = None,
        parser_used: str | None = None,
        fallback_used: bool = False,
        parse_message: str | None = None,
    ) -> None:
        super().__init__(master)
        self.assignments = assignments
        self.on_imported = on_imported
        self.parser_used = parser_used
        self.fallback_used = fallback_used
        self.parse_message = parse_message
        self.records: list[dict[str, Any]] = []

        self.title("Review Imported Assignments")
        self.geometry("980x700")
        self.minsize(860, 600)
        self.configure(fg_color=theme.WINDOW)
        self.transient(master)
        self.grab_set()

        self.grid_rowconfigure(1, weight=1)
        self.grid_columnconfigure(0, weight=1)

        self._build_header()
        self._build_body()
        self._build_footer()

    def _build_header(self) -> None:
        header = ctk.CTkFrame(self, fg_color="transparent")
        header.grid(row=0, column=0, sticky="ew", padx=28, pady=(24, 14))
        header.grid_columnconfigure(1, weight=1)

        icon = ctk.CTkLabel(
            header,
            text="↗",
            width=44,
            height=44,
            corner_radius=14,
            fg_color=theme.ACCENT_SOFT,
            text_color=theme.ACCENT,
            font=theme.font(20, "bold"),
        )
        icon.grid(row=0, column=0, rowspan=3, padx=(0, 12), sticky="n")

        title = ctk.CTkLabel(
            header,
            text="Review imported assignments",
            font=theme.font(24, "bold"),
            text_color=theme.TEXT_PRIMARY,
            anchor="w",
        )
        title.grid(row=0, column=1, sticky="ew")

        self.status_label = ctk.CTkLabel(
            header,
            text=f"{len(self.assignments)} possible assignments are ready for review.",
            text_color=theme.TEXT_SECONDARY,
            font=theme.font(11),
            anchor="w",
        )
        self.status_label.grid(row=1, column=1, sticky="ew", pady=(3, 0))

        parser_text = f"Parser used: {self.parser_used or 'unknown'}"
        if self.parse_message:
            parser_text = f"{parser_text}. {self.parse_message}"
        elif self.fallback_used:
            parser_text = f"{parser_text}. AI parser was not available. Rule-based parser was used instead."

        self.parser_label = ctk.CTkLabel(
            header,
            text=parser_text,
            text_color=theme.WARNING if self.fallback_used else theme.TEXT_TERTIARY,
            font=theme.font(10),
            anchor="w",
            wraplength=820,
        )
        self.parser_label.grid(row=2, column=1, sticky="ew", pady=(3, 0))

    def _build_body(self) -> None:
        if not self.assignments:
            empty_label = ctk.CTkLabel(
                self,
                text="No assignments found. You can try another HTML file or paste text manually later.",
                text_color=theme.TEXT_SECONDARY,
                wraplength=620,
                font=theme.font(16),
            )
            empty_label.grid(row=1, column=0, padx=24, pady=30)
            return

        self.scroll_frame = ctk.CTkScrollableFrame(
            self,
            corner_radius=0,
            fg_color="transparent",
            scrollbar_button_color=theme.BORDER_STRONG,
            scrollbar_button_hover_color=theme.TEXT_TERTIARY,
        )
        self.scroll_frame.grid(row=1, column=0, sticky="nsew", padx=28, pady=(0, 14))
        self.scroll_frame.grid_columnconfigure(0, weight=1)

        for row, assignment in enumerate(self.assignments):
            self._add_assignment_card(row, assignment)

    def _build_footer(self) -> None:
        footer = ctk.CTkFrame(self, fg_color="transparent")
        footer.grid(row=2, column=0, sticky="ew", padx=28, pady=(0, 22))
        footer.grid_columnconfigure(0, weight=1)

        cancel_button = ctk.CTkButton(
            footer,
            text="Cancel",
            width=96,
            height=40,
            corner_radius=13,
            border_width=1,
            border_color=theme.BORDER_STRONG,
            fg_color=theme.SURFACE,
            hover_color=theme.SURFACE_HOVER,
            text_color=theme.TEXT_PRIMARY,
            font=theme.font(12, "bold"),
            command=self.destroy,
        )
        cancel_button.grid(row=0, column=1, padx=(0, 10))

        import_all_button = ctk.CTkButton(
            footer,
            text="Import All",
            width=118,
            height=40,
            corner_radius=13,
            fg_color=theme.ACCENT,
            hover_color=theme.ACCENT_HOVER,
            text_color="#FFFFFF",
            font=theme.font(12, "bold"),
            command=self.import_all,
            state="normal" if self.assignments else "disabled",
        )
        import_all_button.grid(row=0, column=2)

    def _add_assignment_card(self, row: int, assignment: dict[str, Any]) -> None:
        card = ctk.CTkFrame(
            self.scroll_frame,
            corner_radius=20,
            fg_color=theme.SURFACE,
            border_width=1,
            border_color=theme.BORDER,
        )
        card.grid(row=row, column=0, sticky="ew", padx=4, pady=(4, 12))
        card.grid_columnconfigure(0, weight=1)
        card.grid_columnconfigure(1, weight=1)

        course_entry = self._entry(card, 0, 0, "Course name", assignment.get("course_name"))
        title_entry = self._entry(card, 0, 1, "Title", assignment.get("title"))
        due_date_entry = self._entry(card, 1, 0, "Due date (YYYY-MM-DD)", assignment.get("due_date"))
        due_time_entry = self._entry(card, 1, 1, "Due time (HH:MM)", assignment.get("due_time"))
        source_name_entry = self._entry(card, 2, 0, "Source name", assignment.get("source_name"))
        source_file_entry = self._entry(card, 2, 1, "Source file", assignment.get("source_file"))

        info_text = f"Confidence: {clean_text(assignment.get('confidence')) or 'medium'}"
        warnings = assignment.get("warnings") or []
        if warnings:
            info_text = f"{info_text} | Warnings: {'; '.join(str(item) for item in warnings)}"

        info_label = ctk.CTkLabel(
            card,
            text=info_text,
            text_color=theme.WARNING if warnings else theme.TEXT_TERTIARY,
            font=theme.font(10),
            anchor="w",
            wraplength=800,
        )
        info_label.grid(row=3, column=0, columnspan=2, sticky="ew", padx=14, pady=(8, 0))

        ctk.CTkLabel(
            card,
            text="Description",
            anchor="w",
            text_color=theme.TEXT_SECONDARY,
            font=theme.font(11, "bold"),
        ).grid(
            row=4,
            column=0,
            columnspan=2,
            sticky="ew",
            padx=14,
            pady=(6, 4),
        )
        description_box = ctk.CTkTextbox(
            card,
            height=78,
            corner_radius=13,
            border_width=1,
            border_color=theme.BORDER,
            fg_color=theme.INPUT,
            text_color=theme.TEXT_PRIMARY,
            font=theme.font(12),
        )
        description_box.grid(row=5, column=0, columnspan=2, sticky="ew", padx=14)
        description_box.insert("1.0", clean_text(assignment.get("description")))

        button_row = ctk.CTkFrame(card, fg_color="transparent")
        button_row.grid(row=6, column=0, columnspan=2, sticky="e", padx=14, pady=14)

        record: dict[str, Any] = {
            "frame": card,
            "status": "pending",
            "course_entry": course_entry,
            "title_entry": title_entry,
            "due_date_entry": due_date_entry,
            "due_time_entry": due_time_entry,
            "description_box": description_box,
            "source_name_entry": source_name_entry,
            "source_file_entry": source_file_entry,
            "source_type": clean_text(assignment.get("source_type")) or "local_html",
            "source_url": clean_text(assignment.get("source_url")) or None,
        }
        self.records.append(record)

        import_button = ctk.CTkButton(
            button_row,
            text="Import",
            width=90,
            height=34,
            corner_radius=11,
            fg_color=theme.ACCENT,
            hover_color=theme.ACCENT_HOVER,
            text_color="#FFFFFF",
            font=theme.font(11, "bold"),
            command=lambda item=record: self.import_one(item),
        )
        import_button.grid(row=0, column=0, padx=(0, 8))

        ignore_button = ctk.CTkButton(
            button_row,
            text="Ignore",
            width=90,
            height=34,
            corner_radius=11,
            border_width=1,
            border_color=theme.BORDER_STRONG,
            fg_color=theme.SURFACE_SUBTLE,
            hover_color=theme.SURFACE_HOVER,
            text_color=theme.TEXT_PRIMARY,
            font=theme.font(11, "bold"),
            command=lambda item=record: self.ignore_one(item),
        )
        ignore_button.grid(row=0, column=1)

    def _entry(
        self,
        parent: ctk.CTkBaseClass,
        row: int,
        column: int,
        label: str,
        value: Any,
        columnspan: int = 1,
    ) -> ctk.CTkEntry:
        frame = ctk.CTkFrame(parent, fg_color="transparent")
        frame.grid(
            row=row,
            column=column,
            columnspan=columnspan,
            sticky="ew",
            padx=14,
            pady=(12 if row == 0 else 6, 0),
        )
        frame.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            frame,
            text=label,
            anchor="w",
            text_color=theme.TEXT_SECONDARY,
            font=theme.font(11, "bold"),
        ).grid(row=0, column=0, sticky="ew", pady=(0, 5))
        entry = ctk.CTkEntry(
            frame,
            height=40,
            corner_radius=12,
            border_width=1,
            border_color=theme.BORDER,
            fg_color=theme.INPUT,
            text_color=theme.TEXT_PRIMARY,
            placeholder_text="No due date" if "Due date" in label else "",
            placeholder_text_color=theme.TEXT_TERTIARY,
            font=theme.font(11),
        )
        entry.grid(row=1, column=0, sticky="ew")
        theme.bind_focus_ring(entry)
        entry.insert(0, clean_text(value))
        return entry

    def import_one(self, record: dict[str, Any]) -> bool:
        try:
            payload = self._payload_from_record(record)
            api_client.create_assignment(payload)
        except (ValueError, api_client.ApiError) as error:
            messagebox.showerror("Cannot import assignment", str(error), parent=self)
            return False

        record["status"] = "imported"
        record["frame"].destroy()
        self._after_record_done()
        if self.on_imported:
            self.on_imported()
        return True

    def ignore_one(self, record: dict[str, Any]) -> None:
        record["status"] = "ignored"
        record["frame"].destroy()
        self._after_record_done()

    def import_all(self) -> None:
        imported_count = 0
        errors = []

        for record in list(self.records):
            if record["status"] != "pending":
                continue

            try:
                payload = self._payload_from_record(record)
                api_client.create_assignment(payload)
            except (ValueError, api_client.ApiError) as error:
                title = record["title_entry"].get().strip() or "Untitled assignment"
                errors.append(f"{title}: {error}")
                continue

            imported_count += 1
            record["status"] = "imported"
            record["frame"].destroy()

        if imported_count and self.on_imported:
            self.on_imported()

        self._after_record_done()

        if errors:
            messagebox.showerror(
                "Some assignments were not imported",
                "\n".join(errors[:6]),
                parent=self,
            )
            return

        messagebox.showinfo("Import complete", f"Imported {imported_count} assignments.", parent=self)
        self.destroy()

    def _payload_from_record(self, record: dict[str, Any]) -> dict[str, Any]:
        course_name = record["course_entry"].get().strip()
        title = record["title_entry"].get().strip()
        due_date_text = record["due_date_entry"].get().strip()
        due_time_text = record["due_time_entry"].get().strip()

        if not course_name:
            raise ValueError("Course name is required before importing.")
        if not title:
            raise ValueError("Title is required before importing.")

        due_date = None
        if due_date_text:
            due_text = f"{due_date_text} {due_time_text}".strip()
            due_at = parse_due_datetime(due_text)
            if due_at is None:
                raise ValueError("Due date must be blank or use YYYY-MM-DD and optional HH:MM.")
            due_date = due_at.strftime("%Y-%m-%d %H:%M")
        elif due_time_text:
            raise ValueError("Due time cannot be imported without a due date.")

        return {
            "course_name": course_name,
            "title": title,
            "due_date": due_date,
            "description": self._empty_to_none(record["description_box"].get("1.0", "end").strip()),
            "status": "not_started",
            "source_name": self._empty_to_none(record["source_name_entry"].get().strip()),
            "source_type": record["source_type"],
            "source_file": self._empty_to_none(record["source_file_entry"].get().strip()),
            "source_url": record["source_url"],
        }

    def _after_record_done(self) -> None:
        pending_count = sum(1 for record in self.records if record["status"] == "pending")
        self.status_label.configure(text=f"{pending_count} assignments left to review.")

    def _empty_to_none(self, value: str) -> str | None:
        return value or None
