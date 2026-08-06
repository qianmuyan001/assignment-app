from __future__ import annotations

from datetime import datetime
from tkinter import messagebox
from typing import Any, Callable

import customtkinter as ctk

try:
    from . import api_client, localization, theme
    from .components import STATUS_VALUES, parse_due_datetime
except ImportError:
    import api_client
    import localization
    import theme
    from components import STATUS_VALUES, parse_due_datetime


class AssignmentForm(ctk.CTkToplevel):
    def __init__(
        self,
        master: ctk.CTkBaseClass,
        assignment: dict[str, Any] | None = None,
        on_saved: Callable[[], None] | None = None,
        language: str = localization.DEFAULT_LANGUAGE,
    ) -> None:
        super().__init__(master)
        self.assignment = assignment
        self.on_saved = on_saved
        self.language = language

        self.title(self.t("form.window.edit") if assignment else self.t("form.window.new"))
        self.geometry("650x720")
        self.minsize(580, 650)
        self.configure(fg_color=theme.WINDOW)
        self.transient(master)
        self.grab_set()

        self.grid_rowconfigure(0, weight=1)
        self.grid_columnconfigure(0, weight=1)
        self._build_form()
        self._load_assignment()

        self.after(120, self.course_entry.focus_set)

    def t(self, key: str, **values: Any) -> str:
        return localization.translate(self.language, key, **values)

    def _status_labels(self) -> dict[str, str]:
        return {value: self.t(f"status.{value}") for value in STATUS_VALUES}

    def _build_form(self) -> None:
        shell = ctk.CTkFrame(self, fg_color="transparent")
        shell.grid(row=0, column=0, padx=28, pady=24, sticky="nsew")
        shell.grid_columnconfigure(0, weight=1)
        shell.grid_rowconfigure(1, weight=1)

        header = ctk.CTkFrame(shell, fg_color="transparent")
        header.grid(row=0, column=0, sticky="ew", pady=(0, 16))
        header.grid_columnconfigure(1, weight=1)

        icon = ctk.CTkLabel(
            header,
            text="✦",
            width=44,
            height=44,
            corner_radius=14,
            fg_color=theme.ACCENT_SOFT,
            text_color=theme.ACCENT,
            font=theme.font(19, "bold"),
        )
        icon.grid(row=0, column=0, rowspan=2, padx=(0, 12))

        heading = ctk.CTkLabel(
            header,
            text=self.t("form.heading.edit") if self.assignment else self.t("form.heading.new"),
            font=theme.font(23, "bold"),
            text_color=theme.TEXT_PRIMARY,
            anchor="w",
        )
        heading.grid(row=0, column=1, sticky="sw")

        subtitle = ctk.CTkLabel(
            header,
            text=self.t("form.subtitle"),
            font=theme.font(11),
            text_color=theme.TEXT_SECONDARY,
            anchor="w",
        )
        subtitle.grid(row=1, column=1, sticky="nw", pady=(2, 0))

        form_card = ctk.CTkScrollableFrame(
            shell,
            fg_color=theme.SURFACE,
            corner_radius=22,
            border_width=1,
            border_color=theme.BORDER,
            scrollbar_button_color=theme.BORDER_STRONG,
            scrollbar_button_hover_color=theme.TEXT_TERTIARY,
        )
        form_card.grid(row=1, column=0, sticky="nsew")
        form_card.grid_columnconfigure(0, weight=1)

        self._section_label(form_card, 0, self.t("form.section.details"))
        self.course_entry = self._add_entry(
            form_card,
            1,
            self.t("form.course"),
            placeholder=self.t("form.course.placeholder"),
        )
        self.title_entry = self._add_entry(
            form_card,
            2,
            self.t("form.title"),
            placeholder=self.t("form.title.placeholder"),
        )

        date_row = ctk.CTkFrame(form_card, fg_color="transparent")
        date_row.grid(row=3, column=0, sticky="ew", padx=20)
        date_row.grid_columnconfigure(0, weight=3)
        date_row.grid_columnconfigure(1, weight=2)

        self.due_date_entry = self._add_entry(
            date_row,
            0,
            self.t("form.due_date"),
            placeholder="YYYY-MM-DD",
            column=0,
            padx=(0, 7),
        )
        self.due_time_entry = self._add_entry(
            date_row,
            0,
            self.t("form.time"),
            placeholder="23:59",
            column=1,
            padx=(7, 0),
        )

        self.description_box = self._add_textbox(
            form_card,
            4,
            self.t("form.description"),
            self.t("form.description.placeholder"),
        )

        self._section_label(form_card, 6, self.t("form.section.source"))
        self.source_name_entry = self._add_entry(
            form_card,
            7,
            self.t("form.source"),
            placeholder=self.t("form.source.placeholder"),
        )
        self.source_url_entry = self._add_entry(
            form_card,
            8,
            self.t("form.source_url"),
            placeholder="https://",
        )

        status_frame = ctk.CTkFrame(form_card, fg_color="transparent")
        status_frame.grid(row=9, column=0, sticky="ew", padx=20, pady=(0, 20))
        status_frame.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            status_frame,
            text=self.t("form.status"),
            anchor="w",
            font=theme.font(11, "bold"),
            text_color=theme.TEXT_SECONDARY,
        ).grid(row=0, column=0, sticky="ew", pady=(0, 6))

        self.status_menu = ctk.CTkOptionMenu(
            status_frame,
            values=[self._status_labels()[value] for value in STATUS_VALUES],
            height=42,
            corner_radius=13,
            fg_color=theme.INPUT,
            button_color=theme.INPUT,
            button_hover_color=theme.SURFACE_HOVER,
            dropdown_fg_color=theme.SURFACE_RAISED,
            dropdown_hover_color=theme.ACCENT_SOFT,
            text_color=theme.TEXT_PRIMARY,
            font=theme.font(12),
            dropdown_font=theme.font(12),
        )
        self.status_menu.grid(row=1, column=0, sticky="ew")

        button_row = ctk.CTkFrame(shell, fg_color="transparent")
        button_row.grid(row=2, column=0, sticky="e", pady=(16, 0))

        cancel_button = ctk.CTkButton(
            button_row,
            text=self.t("form.cancel"),
            width=94,
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
        cancel_button.grid(row=0, column=0, padx=(0, 9))

        save_button = ctk.CTkButton(
            button_row,
            text=self.t("form.save"),
            width=142,
            height=40,
            corner_radius=13,
            fg_color=theme.ACCENT,
            hover_color=theme.ACCENT_HOVER,
            text_color="#FFFFFF",
            font=theme.font(12, "bold"),
            command=self._save,
        )
        save_button.grid(row=0, column=1)

    def _section_label(
        self,
        parent: ctk.CTkBaseClass,
        row: int,
        text: str,
    ) -> None:
        ctk.CTkLabel(
            parent,
            text=text,
            anchor="w",
            font=theme.font(10, "bold"),
            text_color=theme.TEXT_TERTIARY,
        ).grid(row=row, column=0, sticky="ew", padx=20, pady=(20, 10))

    def _add_entry(
        self,
        parent: ctk.CTkBaseClass,
        row: int,
        label: str,
        placeholder: str = "",
        column: int = 0,
        padx: tuple[int, int] = (20, 20),
    ) -> ctk.CTkEntry:
        frame = ctk.CTkFrame(parent, fg_color="transparent")
        frame.grid(row=row, column=column, sticky="ew", padx=padx)
        frame.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            frame,
            text=label,
            anchor="w",
            font=theme.font(11, "bold"),
            text_color=theme.TEXT_SECONDARY,
        ).grid(row=0, column=0, sticky="ew", pady=(0, 6))

        entry = ctk.CTkEntry(
            frame,
            height=42,
            corner_radius=13,
            border_width=1,
            border_color=theme.BORDER,
            fg_color=theme.INPUT,
            text_color=theme.TEXT_PRIMARY,
            placeholder_text=placeholder,
            placeholder_text_color=theme.TEXT_TERTIARY,
            font=theme.font(12),
        )
        entry.grid(row=1, column=0, sticky="ew", pady=(0, 13))
        theme.bind_focus_ring(entry)
        return entry

    def _add_textbox(
        self,
        parent: ctk.CTkBaseClass,
        row: int,
        label: str,
        placeholder: str,
    ) -> ctk.CTkTextbox:
        frame = ctk.CTkFrame(parent, fg_color="transparent")
        frame.grid(row=row, column=0, sticky="ew", padx=20)
        frame.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            frame,
            text=label,
            anchor="w",
            font=theme.font(11, "bold"),
            text_color=theme.TEXT_SECONDARY,
        ).grid(row=0, column=0, sticky="ew", pady=(0, 6))

        textbox = ctk.CTkTextbox(
            frame,
            height=94,
            corner_radius=13,
            border_width=1,
            border_color=theme.BORDER,
            fg_color=theme.INPUT,
            text_color=theme.TEXT_PRIMARY,
            font=theme.font(12),
        )
        textbox.grid(row=1, column=0, sticky="ew", pady=(0, 12))
        theme.bind_focus_ring(textbox, textbox._textbox)
        # CTkTextbox has no native placeholder, so the clear label above keeps
        # the control understandable without changing stored values.
        textbox._textbox.configure(insertbackground=theme.resolved(theme.TEXT_PRIMARY))
        return textbox

    def _load_assignment(self) -> None:
        self.status_menu.set(self._status_labels()["not_started"])
        self.due_time_entry.insert(0, "23:59")

        if not self.assignment:
            return

        self.course_entry.insert(0, str(self.assignment.get("course_name") or ""))
        self.title_entry.insert(0, str(self.assignment.get("title") or ""))
        self.description_box.insert(
            "1.0",
            str(self.assignment.get("description") or ""),
        )
        self.source_name_entry.insert(
            0,
            str(
                self.assignment.get("source_name")
                or self.assignment.get("link")
                or ""
            ),
        )
        self.source_url_entry.insert(
            0,
            str(self.assignment.get("source_url") or ""),
        )

        status = str(self.assignment.get("status") or "not_started")
        if status in STATUS_VALUES:
            self.status_menu.set(self._status_labels()[status])

        due_at = parse_due_datetime(self.assignment.get("due_date"))
        if due_at is not None:
            self.due_date_entry.insert(0, due_at.strftime("%Y-%m-%d"))
            self.due_time_entry.delete(0, "end")
            self.due_time_entry.insert(0, due_at.strftime("%H:%M"))

    def _save(self) -> None:
        try:
            payload = self._payload_from_form()
        except ValueError as error:
            messagebox.showerror(self.t("form.save_error"), str(error), parent=self)
            return

        try:
            if self.assignment:
                api_client.update_assignment(int(self.assignment["id"]), payload)
            else:
                api_client.create_assignment(payload)
        except (api_client.ApiError, KeyError, ValueError) as error:
            messagebox.showerror(self.t("form.save_error"), str(error), parent=self)
            return

        if self.on_saved:
            self.on_saved()
        self.destroy()

    def _payload_from_form(self) -> dict[str, Any]:
        course_name = self.course_entry.get().strip()
        title = self.title_entry.get().strip()
        due_date = self.due_date_entry.get().strip()
        due_time = self.due_time_entry.get().strip() or "23:59"

        if not course_name:
            raise ValueError(self.t("form.error.course"))
        if not title:
            raise ValueError(self.t("form.error.title"))
        due_at = None
        if due_date:
            due_at = self._parse_due_date_and_time(due_date, due_time)

        payload = {
            "course_name": course_name,
            "title": title,
            "due_date": due_at.strftime("%Y-%m-%d %H:%M") if due_at else None,
            "description": self._empty_to_none(
                self.description_box.get("1.0", "end").strip()
            ),
            "source_name": self._empty_to_none(
                self.source_name_entry.get().strip()
            ),
            "source_url": self._empty_to_none(
                self.source_url_entry.get().strip()
            ),
            "status": self._status_value(),
        }

        if self.assignment:
            payload["source_type"] = self.assignment.get("source_type")
            payload["source_file"] = self.assignment.get("source_file")
        else:
            payload["source_type"] = "manual"

        return payload

    def _status_value(self) -> str:
        selected = self.status_menu.get()
        for value, label in self._status_labels().items():
            if selected == label:
                return value
        return "not_started"

    def _parse_due_date_and_time(self, due_date: str, due_time: str) -> datetime:
        try:
            return datetime.strptime(
                f"{due_date} {due_time}",
                "%Y-%m-%d %H:%M",
            )
        except ValueError as error:
            raise ValueError(
                self.t("form.error.date")
            ) from error

    def _empty_to_none(self, value: str) -> str | None:
        return value or None
