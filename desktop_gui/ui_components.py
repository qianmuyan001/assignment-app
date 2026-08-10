from __future__ import annotations

from datetime import date
from tkinter import TclError
from typing import Any, Callable

import customtkinter as ctk

try:
    from .components import (
        clean_text,
        parse_due_datetime,
        source_text,
    )
    from . import localization, theme
except ImportError:
    from components import (
        clean_text,
        parse_due_datetime,
        source_text,
    )
    import localization
    import theme


class MetricCard(ctk.CTkFrame):
    def __init__(
        self,
        master: ctk.CTkBaseClass,
        label: str,
        accent: str,
        **kwargs: Any,
    ) -> None:
        super().__init__(
            master,
            fg_color=theme.SURFACE,
            corner_radius=18,
            border_width=1,
            border_color=theme.BORDER,
            **kwargs,
        )
        self.grid_columnconfigure(1, weight=1)

        marker = ctk.CTkFrame(self, width=4, height=42, corner_radius=4, fg_color=accent)
        marker.grid(row=0, column=0, rowspan=2, padx=(16, 12), pady=16)
        marker.grid_propagate(False)

        self.value_label = ctk.CTkLabel(
            self,
            text="0",
            font=theme.font(25, "bold"),
            text_color=theme.TEXT_PRIMARY,
            anchor="w",
        )
        self.value_label.grid(row=0, column=1, sticky="sw", padx=(0, 14), pady=(13, 0))

        self.name_label = ctk.CTkLabel(
            self,
            text=label,
            font=theme.font(12, "normal"),
            text_color=theme.TEXT_SECONDARY,
            anchor="w",
        )
        self.name_label.grid(row=1, column=1, sticky="nw", padx=(0, 14), pady=(0, 13))

    def set_value(self, value: int) -> None:
        self.value_label.configure(text=str(value))


class AssignmentCard(ctk.CTkFrame):
    def __init__(
        self,
        master: ctk.CTkBaseClass,
        assignment: dict[str, Any],
        on_edit: Callable[[dict[str, Any]], None],
        on_delete: Callable[[dict[str, Any], "AssignmentCard"], None],
        on_complete: Callable[[dict[str, Any]], None],
        animations_enabled: bool = True,
        language: str = localization.DEFAULT_LANGUAGE,
    ) -> None:
        super().__init__(
            master,
            fg_color=theme.SURFACE,
            corner_radius=20,
            border_width=1,
            border_color=theme.BORDER,
        )
        self.assignment = assignment
        self.language = language
        self.animations_enabled = animations_enabled
        self._hover_after_id: str | None = None
        self._animation_after_id: str | None = None
        self._current_fill = theme.resolved(theme.SURFACE)

        self.grid_columnconfigure(1, weight=1)
        self._build(on_edit, on_delete, on_complete)
        self.after(10, self._bind_hover_tree)

    def t(self, key: str, **values: Any) -> str:
        return localization.translate(self.language, key, **values)

    def _build(
        self,
        on_edit: Callable[[dict[str, Any]], None],
        on_delete: Callable[[dict[str, Any], "AssignmentCard"], None],
        on_complete: Callable[[dict[str, Any]], None],
    ) -> None:
        status = clean_text(self.assignment.get("status")) or "todo"
        completed = status in {"completed", "done"}
        due_at = parse_due_datetime(self.assignment.get("due_date"))

        accent_color = self._accent_color(status, due_at)
        accent = ctk.CTkFrame(self, width=5, corner_radius=5, fg_color=accent_color)
        accent.grid(row=0, column=0, sticky="ns", padx=(14, 0), pady=16)
        accent.grid_propagate(False)

        body = ctk.CTkFrame(self, fg_color="transparent")
        body.grid(row=0, column=1, sticky="nsew", padx=(15, 18), pady=15)
        body.grid_columnconfigure(0, weight=1)

        course = clean_text(self.assignment.get("course_name")) or self.t("card.no_course")
        course_label = ctk.CTkLabel(
            body,
            text=course.upper(),
            font=theme.font(11, "bold"),
            text_color=accent_color,
            anchor="w",
        )
        course_label.grid(row=0, column=0, sticky="w")

        status_fill, status_text = self._status_colors(status)
        status_badge = ctk.CTkLabel(
            body,
            text=self.t(f"status.{status}"),
            height=25,
            corner_radius=12,
            fg_color=status_fill,
            text_color=status_text,
            font=theme.font(11, "bold"),
            padx=10,
        )
        status_badge.grid(row=0, column=1, sticky="e")

        title = clean_text(self.assignment.get("title")) or self.t("card.untitled")
        title_label = ctk.CTkLabel(
            body,
            text=title,
            font=theme.font(18, "bold"),
            text_color=theme.TEXT_PRIMARY,
            anchor="w",
            justify="left",
        )
        title_label.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(7, 0))

        due_label = ctk.CTkLabel(
            body,
            text=self._due_display(status, due_at),
            font=theme.font(13, "normal"),
            text_color=self._due_color(status, due_at),
            anchor="w",
        )
        due_label.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(3, 0))

        description = clean_text(self.assignment.get("description"))
        if description:
            description_label = ctk.CTkLabel(
                body,
                text=self._preview(description),
                font=theme.font(13, "normal"),
                text_color=theme.TEXT_SECONDARY,
                anchor="w",
                justify="left",
                wraplength=680,
            )
            description_label.grid(
                row=3,
                column=0,
                columnspan=2,
                sticky="ew",
                pady=(10, 0),
            )
            self._description_label = description_label
        else:
            self._description_label = None

        footer = ctk.CTkFrame(body, fg_color="transparent")
        footer.grid(row=4, column=0, columnspan=2, sticky="ew", pady=(13, 0))
        footer.grid_columnconfigure(0, weight=1)

        source = source_text(self.assignment)
        if source == "None":
            source = self.t("card.no_source")
        source_badge = ctk.CTkLabel(
            footer,
            text=f"  ↗  {source}  ",
            height=28,
            corner_radius=10,
            fg_color=theme.SURFACE_SUBTLE,
            text_color=theme.TEXT_SECONDARY,
            font=theme.font(11, "normal"),
            anchor="w",
        )
        source_badge.grid(row=0, column=0, sticky="w")

        actions = ctk.CTkFrame(footer, fg_color="transparent")
        actions.grid(row=0, column=1, sticky="e")

        edit_button = self._secondary_button(
            actions,
            self.t("action.edit"),
            64,
            lambda: on_edit(self.assignment),
        )
        edit_button.grid(row=0, column=0, padx=(0, 7))

        complete_button = ctk.CTkButton(
            actions,
            text=self.t("action.done"),
            width=78,
            height=32,
            corner_radius=11,
            border_width=0,
            fg_color=theme.SUCCESS_SOFT if not completed else theme.SURFACE_SUBTLE,
            hover_color=theme.SUCCESS_SOFT,
            text_color=theme.SUCCESS if not completed else theme.TEXT_TERTIARY,
            font=theme.font(12, "bold"),
            state="disabled" if completed else "normal",
            command=lambda: on_complete(self.assignment),
        )
        complete_button.grid(row=0, column=1, padx=(0, 7))

        delete_button = ctk.CTkButton(
            actions,
            text="×",
            width=34,
            height=32,
            corner_radius=11,
            border_width=0,
            fg_color=theme.DANGER_SOFT,
            hover_color=theme.DANGER,
            text_color=theme.DANGER,
            font=theme.font(19, "normal"),
            command=lambda: on_delete(self.assignment, self),
        )
        delete_button.grid(row=0, column=2)

        self.bind("<Configure>", self._update_wraplength, add="+")

    def _secondary_button(
        self,
        master: ctk.CTkBaseClass,
        text: str,
        width: int,
        command: Callable[[], None],
    ) -> ctk.CTkButton:
        return ctk.CTkButton(
            master,
            text=text,
            width=width,
            height=32,
            corner_radius=11,
            border_width=1,
            border_color=theme.BORDER,
            fg_color=theme.SURFACE_SUBTLE,
            hover_color=theme.SURFACE_HOVER,
            text_color=theme.TEXT_PRIMARY,
            font=theme.font(12, "bold"),
            command=command,
        )

    def _update_wraplength(self, event: Any) -> None:
        if self._description_label is not None:
            self._description_label.configure(wraplength=max(280, event.width - 95))

    def _bind_hover_tree(self) -> None:
        if not self.winfo_exists():
            return

        def bind_widget(widget: Any) -> None:
            widget.bind("<Enter>", self._handle_enter, add="+")
            widget.bind("<Leave>", self._handle_leave, add="+")
            for child in widget.winfo_children():
                bind_widget(child)

        bind_widget(self)

    def _handle_enter(self, _event: Any) -> None:
        if self._hover_after_id:
            try:
                self.after_cancel(self._hover_after_id)
            except TclError:
                pass
            self._hover_after_id = None
        if self.animations_enabled:
            try:
                self.grid_configure(padx=(0, 2), pady=(2, 10))
            except TclError:
                pass
        self._animate_fill(theme.resolved(theme.SURFACE_HOVER), theme.resolved(theme.BORDER_ACTIVE))

    def _handle_leave(self, _event: Any) -> None:
        def settle() -> None:
            self._hover_after_id = None
            try:
                hovered = self.winfo_containing(self.winfo_pointerx(), self.winfo_pointery())
            except TclError:
                return
            if hovered is not None and self._is_descendant(hovered):
                return
            if self.animations_enabled:
                try:
                    self.grid_configure(padx=(0, 5), pady=(4, 8))
                except TclError:
                    return
            self._animate_fill(theme.resolved(theme.SURFACE), theme.resolved(theme.BORDER))

        self._hover_after_id = self.after(40, settle)

    def _is_descendant(self, widget: Any) -> bool:
        current = widget
        while current is not None:
            if current == self:
                return True
            current = getattr(current, "master", None)
        return False

    def _animate_fill(self, target_fill: str, target_border: str) -> None:
        if not self.animations_enabled:
            self.configure(fg_color=target_fill, border_color=target_border)
            self._current_fill = target_fill
            return

        if self._animation_after_id:
            try:
                self.after_cancel(self._animation_after_id)
            except TclError:
                pass

        start_fill = self._current_fill
        start_border = theme.resolved(theme.BORDER)
        steps = 6

        def frame(step: int) -> None:
            amount = step / steps
            try:
                fill = theme.blend(start_fill, target_fill, amount)
                border = theme.blend(start_border, target_border, amount)
                self.configure(fg_color=fill, border_color=border)
                self._current_fill = fill
            except TclError:
                return
            if step < steps:
                self._animation_after_id = self.after(22, lambda: frame(step + 1))
            else:
                self._animation_after_id = None

        frame(1)

    def play_exit(self, on_finished: Callable[[], None]) -> None:
        if not self.animations_enabled:
            on_finished()
            return

        start_fill = self._current_fill
        end_fill = theme.resolved(theme.WINDOW)
        steps = 7

        def frame(step: int) -> None:
            amount = step / steps
            try:
                self.configure(
                    fg_color=theme.blend(start_fill, end_fill, amount),
                    border_color=theme.blend(
                        theme.resolved(theme.BORDER),
                        end_fill,
                        amount,
                    ),
                )
                self.grid_configure(padx=(step * 9, 0))
            except TclError:
                on_finished()
                return
            if step < steps:
                self.after(24, lambda: frame(step + 1))
            else:
                on_finished()

        frame(1)

    def _accent_color(self, status: str, due_at: Any) -> str:
        if status in {"completed", "done"}:
            return theme.SUCCESS
        if due_at is not None and due_at.date() < date.today():
            return theme.DANGER
        if due_at is not None and 0 <= (due_at.date() - date.today()).days <= 2:
            return theme.WARNING
        if status == "in_progress":
            return theme.ACCENT
        return theme.PURPLE

    def _status_colors(self, status: str) -> tuple[theme.Color, theme.Color]:
        if status in {"completed", "done"}:
            return theme.SUCCESS_SOFT, theme.SUCCESS
        if status == "in_progress":
            return theme.ACCENT_SOFT, theme.ACCENT
        if status == "ignored":
            return theme.SURFACE_SUBTLE, theme.TEXT_TERTIARY
        return theme.PURPLE_SOFT, theme.PURPLE

    def _due_color(self, status: str, due_at: Any) -> theme.Color:
        if status in {"completed", "done"}:
            return theme.TEXT_TERTIARY
        if due_at is None:
            return theme.TEXT_TERTIARY
        days = (due_at.date() - date.today()).days
        if days < 0:
            return theme.DANGER
        if days <= 2:
            return theme.WARNING
        return theme.TEXT_SECONDARY

    def _due_display(self, status: str, due_at: Any) -> str:
        if due_at is None:
            return self.t("due.none")
        if self.language == "zh":
            date_part = f"{due_at.month}月{due_at.day}日"
            time_part = due_at.strftime("%H:%M")
        else:
            date_part = due_at.strftime("%a, %b %d").replace(" 0", " ")
            time_part = due_at.strftime("%I:%M %p").lstrip("0")
        if status in {"completed", "done"}:
            return self.t("due.completed", date=date_part, time=time_part)
        days = (due_at.date() - date.today()).days
        if days == 0:
            relative = self.t("due.today")
        elif days == 1:
            relative = self.t("due.tomorrow")
        elif days > 1:
            relative = self.t("due.in_days", days=days)
        elif days == -1:
            relative = self.t("due.overdue_one")
        else:
            relative = self.t("due.overdue_days", days=abs(days))
        return self.t("due.detail", relative=relative, date=date_part, time=time_part)

    def _preview(self, description: str) -> str:
        normalized = " ".join(description.split())
        return normalized if len(normalized) <= 190 else f"{normalized[:187].rstrip()}…"
