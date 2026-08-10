from __future__ import annotations

import sys
from datetime import date, datetime, timedelta
from pathlib import Path
from tkinter import TclError, filedialog, messagebox
from typing import Any

import customtkinter as ctk


PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

try:
    from . import api_client, localization, theme
    from .assignment_form import AssignmentForm
    from .components import (
        assignment_matches_search,
        build_summary,
        clean_text,
        parse_due_datetime,
        sort_assignments_by_due_date,
    )
    from .html_import_window import PendingImportWindow
    from .ui_components import AssignmentCard, MetricCard
except ImportError:
    import api_client
    import localization
    import theme
    from assignment_form import AssignmentForm
    from components import (
        assignment_matches_search,
        build_summary,
        clean_text,
        parse_due_datetime,
        sort_assignments_by_due_date,
    )
    from html_import_window import PendingImportWindow
    from ui_components import AssignmentCard, MetricCard


STATUS_FILTERS = ["all", "todo", "in_progress", "done"]
NAVIGATION = [
    ("all", "▦"),
    ("today", "◷"),
    ("week", "◇"),
    ("completed", "✓"),
    ("sources", "↗"),
    ("settings", "⚙"),
]


class AssignmentApp(ctk.CTk):
    def __init__(self) -> None:
        super().__init__()
        self.language = localization.load_language()
        self.title(self.t("app.title"))
        self.geometry("1280x800")
        self.minsize(960, 640)
        self.configure(fg_color=theme.WINDOW)

        self.active_view = "all"
        self.appearance_preference = "System"
        self.motion_enabled = True
        self._compact_sidebar = False
        self._render_after_ids: list[str] = []
        self.all_assignments: list[dict[str, Any]] = []
        self.service_online: bool | None = None
        self.metric_cards: dict[str, MetricCard] = {}
        self.nav_buttons: dict[str, ctk.CTkButton] = {}
        self.settings_panel: ctk.CTkFrame | None = None

        self.grid_rowconfigure(0, weight=1)
        self.grid_columnconfigure(1, weight=1)

        try:
            self.attributes("-alpha", 0.0)
        except TclError:
            pass

        self._build_sidebar()
        self._build_workspace()
        self.bind("<Configure>", self._handle_resize, add="+")

        self.load_assignments()
        self.after(30, self._fade_window)

    def t(self, key: str, **values: Any) -> str:
        return localization.translate(self.language, key, **values)

    def _status_labels(self) -> dict[str, str]:
        return {value: self.t(f"filter.{value}") for value in STATUS_FILTERS}

    def _build_sidebar(self) -> None:
        self.sidebar = ctk.CTkFrame(
            self,
            width=190 if self._compact_sidebar else 224,
            corner_radius=0,
            fg_color=theme.SIDEBAR,
            border_width=0,
        )
        self.sidebar.grid(row=0, column=0, sticky="nsew")
        self.sidebar.grid_propagate(False)
        self.sidebar.grid_columnconfigure(0, weight=1)
        self.sidebar.grid_rowconfigure(9, weight=1)

        brand = ctk.CTkFrame(self.sidebar, fg_color="transparent")
        brand.grid(row=0, column=0, sticky="ew", padx=18, pady=(24, 26))
        brand.grid_columnconfigure(1, weight=1)

        mark = ctk.CTkLabel(
            brand,
            text="A",
            width=40,
            height=40,
            corner_radius=13,
            fg_color=theme.ACCENT,
            text_color="#FFFFFF",
            font=theme.font(19, "bold"),
        )
        mark.grid(row=0, column=0, rowspan=2, padx=(0, 11))

        self.brand_title = ctk.CTkLabel(
            brand,
            text=self.t("app.title"),
            font=theme.font(16, "bold"),
            text_color=theme.TEXT_PRIMARY,
            anchor="w",
        )
        self.brand_title.grid(row=0, column=1, sticky="sw")

        self.brand_subtitle = ctk.CTkLabel(
            brand,
            text="" if self._compact_sidebar else self.t("brand.subtitle"),
            font=theme.font(10),
            text_color=theme.TEXT_TERTIARY,
            anchor="w",
        )
        self.brand_subtitle.grid(row=1, column=1, sticky="nw")

        section_label = ctk.CTkLabel(
            self.sidebar,
            text=self.t("nav.section"),
            font=theme.font(10, "bold"),
            text_color=theme.TEXT_TERTIARY,
            anchor="w",
        )
        section_label.grid(row=1, column=0, sticky="ew", padx=22, pady=(0, 8))

        for row, (key, icon) in enumerate(NAVIGATION, start=2):
            button = ctk.CTkButton(
                self.sidebar,
                text=f"{icon}   {self.t(f'nav.{key}')}",
                height=43,
                corner_radius=13,
                fg_color="transparent",
                hover_color=theme.SURFACE_SUBTLE,
                text_color=theme.TEXT_SECONDARY,
                font=theme.font(13, "normal"),
                anchor="w",
                border_width=0,
                command=lambda view=key: self.select_view(view),
            )
            button.grid(row=row, column=0, sticky="ew", padx=12, pady=2)
            self.nav_buttons[key] = button

        footer = ctk.CTkFrame(
            self.sidebar,
            fg_color=theme.SURFACE_SUBTLE,
            corner_radius=15,
            border_width=1,
            border_color=theme.BORDER,
        )
        footer.grid(row=10, column=0, sticky="ew", padx=14, pady=16)
        footer.grid_columnconfigure(1, weight=1)

        self.connection_dot = ctk.CTkLabel(
            footer,
            text="●",
            width=20,
            text_color=theme.TEXT_TERTIARY,
            font=theme.font(10),
        )
        self.connection_dot.grid(row=0, column=0, padx=(10, 2), pady=11)

        self.connection_label = ctk.CTkLabel(
            footer,
            text=self.t("connection.connecting"),
            text_color=theme.TEXT_SECONDARY,
            font=theme.font(10),
            anchor="w",
        )
        self.connection_label.grid(row=0, column=1, sticky="ew", padx=(0, 10), pady=11)
        self._update_nav_styles()

    def _build_workspace(self) -> None:
        self.workspace = ctk.CTkFrame(self, fg_color="transparent", corner_radius=0)
        self.workspace.grid(row=0, column=1, sticky="nsew")
        self.workspace.grid_columnconfigure(0, weight=1)
        self.workspace.grid_rowconfigure(3, weight=1)

        self._build_header()
        self._build_summary()
        self._build_toolbar()
        self._build_assignment_list()
        self._build_status_bar()

    def _build_header(self) -> None:
        header = ctk.CTkFrame(self.workspace, fg_color="transparent")
        header.grid(row=0, column=0, sticky="ew", padx=30, pady=(25, 16))
        header.grid_columnconfigure(0, weight=1)

        copy = ctk.CTkFrame(header, fg_color="transparent")
        copy.grid(row=0, column=0, sticky="w")

        self.view_title_label = ctk.CTkLabel(
            copy,
            text=self.t("view.all.title"),
            font=theme.font(30, "bold"),
            text_color=theme.TEXT_PRIMARY,
            anchor="w",
        )
        self.view_title_label.grid(row=0, column=0, sticky="w")

        self.view_subtitle_label = ctk.CTkLabel(
            copy,
            text=self._header_subtitle("all"),
            font=theme.font(12),
            text_color=theme.TEXT_SECONDARY,
            anchor="w",
        )
        self.view_subtitle_label.grid(row=1, column=0, sticky="w", pady=(4, 0))

        actions = ctk.CTkFrame(header, fg_color="transparent")
        actions.grid(row=0, column=1, sticky="e", padx=(18, 0))

        import_button = ctk.CTkButton(
            actions,
            text=self.t("action.import_html"),
            width=128,
            height=40,
            corner_radius=13,
            border_width=1,
            border_color=theme.BORDER_STRONG,
            fg_color=theme.SURFACE,
            hover_color=theme.SURFACE_HOVER,
            text_color=theme.TEXT_PRIMARY,
            font=theme.font(12, "bold"),
            command=self.import_from_html,
        )
        import_button.grid(row=0, column=0, padx=(0, 9))

        add_button = ctk.CTkButton(
            actions,
            text=self.t("action.new_assignment"),
            width=146,
            height=40,
            corner_radius=13,
            border_width=0,
            fg_color=theme.ACCENT,
            hover_color=theme.ACCENT_HOVER,
            text_color="#FFFFFF",
            font=theme.font(12, "bold"),
            command=self.open_add_form,
        )
        add_button.grid(row=0, column=1)

    def _build_summary(self) -> None:
        self.summary_frame = ctk.CTkFrame(self.workspace, fg_color="transparent")
        self.summary_frame.grid(row=1, column=0, sticky="ew", padx=30, pady=(0, 15))

        items = [
            ("incomplete", self.t("metric.open"), theme.PURPLE),
            ("due_today", self.t("metric.due_today"), theme.WARNING),
            ("due_this_week", self.t("metric.this_week"), theme.ACCENT),
            ("completed", self.t("metric.completed"), theme.SUCCESS),
        ]

        for index, (key, label, accent) in enumerate(items):
            self.summary_frame.grid_columnconfigure(index, weight=1, uniform="summary")
            tile = MetricCard(self.summary_frame, label=label, accent=accent)
            tile.grid(
                row=0,
                column=index,
                sticky="ew",
                padx=(0, 10 if index < len(items) - 1 else 0),
            )
            self.metric_cards[key] = tile

    def _build_toolbar(self) -> None:
        self.toolbar = ctk.CTkFrame(
            self.workspace,
            fg_color=theme.SURFACE,
            corner_radius=18,
            border_width=1,
            border_color=theme.BORDER,
        )
        self.toolbar.grid(row=2, column=0, sticky="ew", padx=30, pady=(0, 14))
        self.toolbar.grid_columnconfigure(0, weight=1)

        self.search_entry = ctk.CTkEntry(
            self.toolbar,
            height=41,
            corner_radius=13,
            border_width=1,
            border_color=theme.BORDER,
            fg_color=theme.INPUT,
            text_color=theme.TEXT_PRIMARY,
            placeholder_text=self.t("search.placeholder"),
            placeholder_text_color=theme.TEXT_TERTIARY,
            font=theme.font(12),
        )
        self.search_entry.grid(row=0, column=0, sticky="ew", padx=(12, 7), pady=11)
        theme.bind_focus_ring(self.search_entry)
        self.search_entry.bind("<KeyRelease>", lambda _event: self.render_assignments())

        self.status_filter = ctk.CTkOptionMenu(
            self.toolbar,
            values=[self._status_labels()[value] for value in STATUS_FILTERS],
            width=132,
            height=41,
            corner_radius=13,
            fg_color=theme.INPUT,
            button_color=theme.INPUT,
            button_hover_color=theme.SURFACE_HOVER,
            dropdown_fg_color=theme.SURFACE_RAISED,
            dropdown_hover_color=theme.ACCENT_SOFT,
            text_color=theme.TEXT_SECONDARY,
            font=theme.font(11),
            dropdown_font=theme.font(11),
            command=lambda _value: self.render_assignments(),
        )
        self.status_filter.grid(row=0, column=1, padx=7, pady=11)
        self.status_filter.set(self._status_labels()["all"])

        self.course_filter = ctk.CTkOptionMenu(
            self.toolbar,
            values=[self.t("filter.all_courses")],
            width=132,
            height=41,
            corner_radius=13,
            fg_color=theme.INPUT,
            button_color=theme.INPUT,
            button_hover_color=theme.SURFACE_HOVER,
            dropdown_fg_color=theme.SURFACE_RAISED,
            dropdown_hover_color=theme.ACCENT_SOFT,
            text_color=theme.TEXT_SECONDARY,
            font=theme.font(11),
            dropdown_font=theme.font(11),
            command=lambda _value: self.render_assignments(),
        )
        self.course_filter.grid(row=0, column=2, padx=7, pady=11)
        self.course_filter.set(self.t("filter.all_courses"))

        self.parser_mode_menu = ctk.CTkOptionMenu(
            self.toolbar,
            values=[self.t("parser.auto"), self.t("parser.ai"), self.t("parser.rule")],
            width=104,
            height=41,
            corner_radius=13,
            fg_color=theme.INPUT,
            button_color=theme.INPUT,
            button_hover_color=theme.SURFACE_HOVER,
            dropdown_fg_color=theme.SURFACE_RAISED,
            dropdown_hover_color=theme.ACCENT_SOFT,
            text_color=theme.TEXT_SECONDARY,
            font=theme.font(11),
            dropdown_font=theme.font(11),
        )
        self.parser_mode_menu.grid(row=0, column=3, padx=7, pady=11)
        self.parser_mode_menu.set(self.t("parser.auto"))

        refresh_button = ctk.CTkButton(
            self.toolbar,
            text="↻",
            width=41,
            height=41,
            corner_radius=13,
            border_width=0,
            fg_color=theme.INPUT,
            hover_color=theme.ACCENT_SOFT,
            text_color=theme.ACCENT,
            font=theme.font(17, "bold"),
            command=self.load_assignments,
        )
        refresh_button.grid(row=0, column=4, padx=(7, 12), pady=11)

    def _build_assignment_list(self) -> None:
        self.list_panel = ctk.CTkFrame(self.workspace, fg_color="transparent")
        self.list_panel.grid(row=3, column=0, sticky="nsew", padx=30)
        self.list_panel.grid_columnconfigure(0, weight=1)
        self.list_panel.grid_rowconfigure(1, weight=1)

        list_header = ctk.CTkFrame(self.list_panel, fg_color="transparent")
        list_header.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        list_header.grid_columnconfigure(0, weight=1)

        self.list_count_label = ctk.CTkLabel(
            list_header,
            text=self.t("list.count.other", count=0),
            font=theme.font(13, "bold"),
            text_color=theme.TEXT_PRIMARY,
            anchor="w",
        )
        self.list_count_label.grid(row=0, column=0, sticky="w")

        sort_label = ctk.CTkLabel(
            list_header,
            text=self.t("list.sort"),
            font=theme.font(11),
            text_color=theme.TEXT_TERTIARY,
            anchor="e",
        )
        sort_label.grid(row=0, column=1, sticky="e")

        self.list_frame = ctk.CTkScrollableFrame(
            self.list_panel,
            fg_color="transparent",
            corner_radius=0,
            scrollbar_button_color=theme.BORDER_STRONG,
            scrollbar_button_hover_color=theme.TEXT_TERTIARY,
        )
        self.list_frame.grid(row=1, column=0, sticky="nsew")
        self.list_frame.grid_columnconfigure(0, weight=1)

    def _build_status_bar(self) -> None:
        footer = ctk.CTkFrame(self.workspace, fg_color="transparent")
        footer.grid(row=4, column=0, sticky="ew", padx=30, pady=(7, 13))
        footer.grid_columnconfigure(0, weight=1)

        self.status_label = ctk.CTkLabel(
            footer,
            text="",
            anchor="w",
            text_color=theme.TEXT_TERTIARY,
            font=theme.font(10),
        )
        self.status_label.grid(row=0, column=0, sticky="ew")

        privacy_label = ctk.CTkLabel(
            footer,
            text=self.t("privacy"),
            anchor="e",
            text_color=theme.TEXT_TERTIARY,
            font=theme.font(10),
        )
        privacy_label.grid(row=0, column=1, sticky="e")

    def select_view(self, view: str) -> None:
        if view not in {key for key, _icon in NAVIGATION}:
            return

        self.active_view = view
        self.status_filter.set(self._status_labels()["all"])
        self._update_nav_styles()
        self._update_header_copy()

        if view == "settings":
            self._show_settings()
            return

        self._hide_settings()
        self.render_assignments()

    def _show_settings(self) -> None:
        self.summary_frame.grid_remove()
        self.toolbar.grid_remove()
        self.list_panel.grid_remove()

        if self.settings_panel is not None and self.settings_panel.winfo_exists():
            self.settings_panel.destroy()

        self.settings_panel = ctk.CTkFrame(self.workspace, fg_color="transparent")
        self.settings_panel.grid(
            row=1,
            column=0,
            rowspan=3,
            sticky="nsew",
            padx=30,
            pady=(0, 10),
        )
        self.settings_panel.grid_columnconfigure(0, weight=1)

        language_card = self._settings_card(
            self.settings_panel,
            self.t("settings.language.title"),
            self.t("settings.language.description"),
        )
        language_card.grid(row=0, column=0, sticky="ew", pady=(0, 12))

        language_selector = ctk.CTkSegmentedButton(
            language_card,
            values=[localization.LANGUAGE_NAMES["en"], localization.LANGUAGE_NAMES["zh"]],
            height=38,
            corner_radius=12,
            border_width=0,
            fg_color=theme.INPUT,
            selected_color=theme.ACCENT,
            selected_hover_color=theme.ACCENT_HOVER,
            unselected_color=theme.INPUT,
            unselected_hover_color=theme.SURFACE_HOVER,
            text_color=theme.TEXT_PRIMARY,
            font=theme.font(11, "bold"),
            command=self._change_language,
        )
        language_selector.grid(row=2, column=0, sticky="w", padx=20, pady=(4, 20))
        language_selector.set(localization.LANGUAGE_NAMES[self.language])

        appearance_card = self._settings_card(
            self.settings_panel,
            self.t("settings.appearance.title"),
            self.t("settings.appearance.description"),
        )
        appearance_card.grid(row=1, column=0, sticky="ew", pady=(0, 12))

        appearance_labels = {
            "System": self.t("settings.appearance.system"),
            "Light": self.t("settings.appearance.light"),
            "Dark": self.t("settings.appearance.dark"),
        }

        appearance_selector = ctk.CTkSegmentedButton(
            appearance_card,
            values=list(appearance_labels.values()),
            height=38,
            corner_radius=12,
            border_width=0,
            fg_color=theme.INPUT,
            selected_color=theme.ACCENT,
            selected_hover_color=theme.ACCENT_HOVER,
            unselected_color=theme.INPUT,
            unselected_hover_color=theme.SURFACE_HOVER,
            text_color=theme.TEXT_PRIMARY,
            font=theme.font(11, "bold"),
            command=lambda value: self._change_appearance(
                next(key for key, label in appearance_labels.items() if label == value)
            ),
        )
        appearance_selector.grid(row=2, column=0, sticky="w", padx=20, pady=(4, 20))
        appearance_selector.set(appearance_labels[self.appearance_preference])

        motion_card = self._settings_card(
            self.settings_panel,
            self.t("settings.motion.title"),
            self.t("settings.motion.description"),
        )
        motion_card.grid(row=2, column=0, sticky="ew", pady=(0, 12))

        self.motion_switch = ctk.CTkSwitch(
            motion_card,
            text=self.t("settings.motion.toggle"),
            progress_color=theme.ACCENT,
            button_color="#FFFFFF",
            button_hover_color="#FFFFFF",
            text_color=theme.TEXT_PRIMARY,
            font=theme.font(12),
            command=self._change_motion,
        )
        self.motion_switch.grid(row=2, column=0, sticky="w", padx=20, pady=(4, 20))
        if self.motion_enabled:
            self.motion_switch.select()

        data_card = self._settings_card(
            self.settings_panel,
            self.t("settings.data.title"),
            self.t("settings.data.description"),
        )
        data_card.grid(row=3, column=0, sticky="ew")

        endpoint = ctk.CTkLabel(
            data_card,
            text=self.t("settings.data.endpoint", url=api_client.BASE_URL),
            height=36,
            corner_radius=11,
            fg_color=theme.INPUT,
            text_color=theme.TEXT_SECONDARY,
            font=theme.font(11),
            padx=12,
        )
        endpoint.grid(row=2, column=0, sticky="w", padx=20, pady=(4, 20))

    def _settings_card(
        self,
        master: ctk.CTkBaseClass,
        title: str,
        description: str,
    ) -> ctk.CTkFrame:
        card = ctk.CTkFrame(
            master,
            fg_color=theme.SURFACE,
            corner_radius=20,
            border_width=1,
            border_color=theme.BORDER,
        )
        card.grid_columnconfigure(0, weight=1)

        title_label = ctk.CTkLabel(
            card,
            text=title,
            font=theme.font(16, "bold"),
            text_color=theme.TEXT_PRIMARY,
            anchor="w",
        )
        title_label.grid(row=0, column=0, sticky="ew", padx=20, pady=(18, 2))

        description_label = ctk.CTkLabel(
            card,
            text=description,
            font=theme.font(11),
            text_color=theme.TEXT_SECONDARY,
            anchor="w",
            justify="left",
        )
        description_label.grid(row=1, column=0, sticky="ew", padx=20, pady=(0, 12))
        return card

    def _hide_settings(self) -> None:
        if self.settings_panel is not None and self.settings_panel.winfo_exists():
            self.settings_panel.destroy()
        self.settings_panel = None
        self.summary_frame.grid()
        self.toolbar.grid()
        self.list_panel.grid()

    def load_assignments(self) -> None:
        self.status_label.configure(text=self.t("status.syncing"))

        try:
            self.all_assignments = api_client.get_assignments()
        except api_client.ApiError as error:
            self.all_assignments = []
            self._update_course_filter()
            self._update_summary()
            self._update_nav_badges()
            if self.active_view != "settings":
                self.render_assignments()
            self.status_label.configure(text=self.t("status.unavailable"))
            self.service_online = False
            self.connection_dot.configure(text_color=theme.DANGER)
            self.connection_label.configure(text=self.t("connection.offline"))
            messagebox.showerror(self.t("dialog.load_error"), str(error), parent=self)
            return

        self._update_course_filter()
        self._update_summary()
        self._update_nav_badges()
        if self.active_view != "settings":
            self.render_assignments()
        self.connection_dot.configure(text_color=theme.SUCCESS)
        self.service_online = True
        self.connection_label.configure(text=self.t("connection.online"))
        self.status_label.configure(
            text=self.t("status.updated", count=len(self.all_assignments))
        )

    def render_assignments(self) -> None:
        self._cancel_pending_renders()
        for child in self.list_frame.winfo_children():
            child.destroy()

        assignments = self._filtered_assignments()
        count = len(assignments)
        count_key = "list.count.one" if count == 1 else "list.count.other"
        self.list_count_label.configure(text=self.t(count_key, count=count))

        if not assignments:
            self._build_empty_state()
            return

        for row, assignment in enumerate(assignments):
            card = AssignmentCard(
                self.list_frame,
                assignment,
                on_edit=self.open_edit_form,
                on_delete=self.delete_assignment,
                on_complete=self.mark_complete,
                animations_enabled=self.motion_enabled,
                language=self.language,
            )
            delay = min(row, 12) * 28 if self.motion_enabled else 0
            after_id = self.after(
                delay,
                lambda item=card, item_row=row: self._mount_card(item, item_row),
            )
            self._render_after_ids.append(after_id)

    def _mount_card(self, card: AssignmentCard, row: int) -> None:
        if not card.winfo_exists() or not self.list_frame.winfo_exists():
            return
        start_top = 13 if self.motion_enabled else 4
        card.grid(
            row=row,
            column=0,
            sticky="ew",
            padx=(0, 5),
            pady=(start_top, 8),
        )
        if self.motion_enabled:
            self._slide_card_up(card, start_top, 0)

    def _slide_card_up(self, card: AssignmentCard, start_top: int, step: int) -> None:
        steps = 5
        if not card.winfo_exists():
            return
        top = round(start_top + (4 - start_top) * (step / steps))
        try:
            card.grid_configure(pady=(top, 8))
        except TclError:
            return
        if step < steps:
            card.after(22, lambda: self._slide_card_up(card, start_top, step + 1))

    def _build_empty_state(self) -> None:
        panel = ctk.CTkFrame(
            self.list_frame,
            fg_color=theme.SURFACE,
            corner_radius=22,
            border_width=1,
            border_color=theme.BORDER,
        )
        panel.grid(row=0, column=0, sticky="ew", padx=(0, 5), pady=(4, 8))
        panel.grid_columnconfigure(0, weight=1)

        icon = ctk.CTkLabel(
            panel,
            text="✓" if self.active_view == "completed" else "◇",
            width=54,
            height=54,
            corner_radius=18,
            fg_color=theme.ACCENT_SOFT,
            text_color=theme.ACCENT,
            font=theme.font(23, "bold"),
        )
        icon.grid(row=0, column=0, pady=(34, 13))

        if not self.all_assignments:
            title = self.t("empty.first.title")
            body = self.t("empty.first.body")
        else:
            title = self.t("empty.filtered.title")
            body = self.t("empty.filtered.body")

        title_label = ctk.CTkLabel(
            panel,
            text=title,
            font=theme.font(18, "bold"),
            text_color=theme.TEXT_PRIMARY,
        )
        title_label.grid(row=1, column=0)

        body_label = ctk.CTkLabel(
            panel,
            text=body,
            font=theme.font(12),
            text_color=theme.TEXT_SECONDARY,
            wraplength=460,
            justify="center",
        )
        body_label.grid(row=2, column=0, pady=(6, 16))

        action = ctk.CTkButton(
            panel,
            text=self.t("action.new_assignment") if not self.all_assignments else self.t("action.clear_filters"),
            height=38,
            corner_radius=12,
            fg_color=theme.ACCENT,
            hover_color=theme.ACCENT_HOVER,
            text_color="#FFFFFF",
            font=theme.font(12, "bold"),
            command=self.open_add_form if not self.all_assignments else self.clear_filters,
        )
        action.grid(row=3, column=0, pady=(0, 34))

    def _filtered_assignments(self) -> list[dict[str, Any]]:
        status_filter = self._selected_status_filter()
        course_filter = self.course_filter.get()
        search_text = self.search_entry.get().strip()

        visible = []
        for assignment in self.all_assignments:
            status = clean_text(assignment.get("status"))
            course = clean_text(assignment.get("course_name"))

            view_matches = self._assignment_matches_view(assignment)
            status_matches = status_filter == "all" or status == status_filter
            course_matches = course_filter == self.t("filter.all_courses") or course == course_filter
            search_matches = assignment_matches_search(assignment, search_text)

            if view_matches and status_matches and course_matches and search_matches:
                visible.append(assignment)

        return sort_assignments_by_due_date(visible)

    def _assignment_matches_view(self, assignment: dict[str, Any]) -> bool:
        status = clean_text(assignment.get("status"))
        completed = status in {"completed", "done"}
        due_at = parse_due_datetime(assignment.get("due_date"))
        today = date.today()

        if self.active_view == "today":
            return due_at is not None and due_at.date() == today
        if self.active_view == "week":
            return (
                not completed
                and due_at is not None
                and today <= due_at.date() <= today + timedelta(days=7)
            )
        if self.active_view == "completed":
            return completed
        if self.active_view == "sources":
            return any(
                clean_text(assignment.get(field))
                for field in (
                    "source_name",
                    "source_file",
                    "source_url",
                    "link",
                )
            )
        return True

    def open_add_form(self) -> None:
        AssignmentForm(self, on_saved=self.load_assignments, language=self.language)

    def open_edit_form(self, assignment: dict[str, Any]) -> None:
        AssignmentForm(
            self,
            assignment=assignment,
            on_saved=self.load_assignments,
            language=self.language,
        )

    def import_from_html(self) -> None:
        file_path = filedialog.askopenfilename(
            parent=self,
            title=self.t("dialog.select_html"),
            filetypes=[
                (self.t("dialog.html_files"), "*.html *.htm"),
                (self.t("dialog.all_files"), "*.*"),
            ],
        )
        if not file_path:
            return

        course_dialog = ctk.CTkInputDialog(
            text=self.t("dialog.default_course"),
            title=self.t("dialog.html_import"),
        )
        default_course_name = course_dialog.get_input()
        if default_course_name is None:
            return

        try:
            from backend.app.services.html_importer import (
                extract_clean_text_from_html,
                read_html_file,
            )
            from backend.app.services.import_pipeline import parse_import_content

            html_content = read_html_file(file_path)
            clean_text_content = extract_clean_text_from_html(html_content)
            source_file = Path(file_path).name
            source_name = default_course_name.strip() or Path(file_path).stem
            parse_result = parse_import_content(
                content=clean_text_content,
                source_info={
                    "source_name": source_name,
                    "source_type": "local_html",
                    "source_file": source_file,
                    "source_url": None,
                    "course_name": default_course_name,
                },
                parser_mode=self._selected_parser_mode(),
            )
        except ImportError as error:
            messagebox.showerror(
                self.t("dialog.import_error"),
                self.t("dialog.import_dependency", error=error),
                parent=self,
            )
            return
        except (OSError, ValueError) as error:
            messagebox.showerror(self.t("dialog.import_error"), str(error), parent=self)
            return

        if parse_result.error:
            messagebox.showerror(self.t("dialog.parse_error"), parse_result.error, parent=self)
            return

        if not parse_result.candidates:
            message = self.t("dialog.no_assignments.body")
            if parse_result.message:
                message = f"{parse_result.message}\n\n{message}"
            messagebox.showinfo(self.t("dialog.no_assignments"), message, parent=self)
            return

        PendingImportWindow(
            self,
            parse_result.candidates,
            on_imported=self.load_assignments,
            parser_used=parse_result.parser_used,
            fallback_used=parse_result.fallback_used,
            parse_message=parse_result.message,
            language=self.language,
        )

    def delete_assignment(
        self,
        assignment: dict[str, Any],
        card: AssignmentCard,
    ) -> None:
        title = clean_text(assignment.get("title")) or self.t("fallback.assignment")
        confirmed = messagebox.askyesno(
            self.t("dialog.delete"),
            self.t("dialog.delete_confirm", title=title),
            parent=self,
        )
        if not confirmed:
            return

        try:
            api_client.delete_assignment(int(assignment["id"]))
        except (api_client.ApiError, KeyError, ValueError) as error:
            messagebox.showerror(self.t("dialog.delete_error"), str(error), parent=self)
            return

        self.status_label.configure(text=self.t("status.removed", title=title))
        card.play_exit(self.load_assignments)

    def mark_complete(self, assignment: dict[str, Any]) -> None:
        try:
            api_client.mark_assignment_complete(int(assignment["id"]))
        except (api_client.ApiError, KeyError, ValueError) as error:
            messagebox.showerror(self.t("dialog.update_error"), str(error), parent=self)
            return
        self.load_assignments()

    def clear_filters(self) -> None:
        self.search_entry.delete(0, "end")
        self.status_filter.set(self._status_labels()["all"])
        self.course_filter.set(self.t("filter.all_courses"))
        self.render_assignments()

    def _update_summary(self) -> None:
        summary = build_summary(self.all_assignments)
        for key, card in self.metric_cards.items():
            card.set_value(summary.get(key, 0))

    def _update_course_filter(self) -> None:
        previous_value = (
            self.course_filter.get() if hasattr(self, "course_filter") else self.t("filter.all_courses")
        )
        courses = sorted(
            {
                clean_text(assignment.get("course_name"))
                for assignment in self.all_assignments
                if clean_text(assignment.get("course_name"))
            }
        )
        values = [self.t("filter.all_courses"), *courses]
        self.course_filter.configure(values=values)
        self.course_filter.set(
            previous_value if previous_value in values else self.t("filter.all_courses")
        )

    def _update_nav_badges(self) -> None:
        summary = build_summary(self.all_assignments)
        source_count = sum(
            1
            for assignment in self.all_assignments
            if any(
                clean_text(assignment.get(field))
                for field in ("source_name", "source_file", "source_url", "link")
            )
        )
        counts = {
            "all": summary["total"],
            "today": summary["due_today"],
            "week": summary["due_this_week"],
            "completed": summary["completed"],
            "sources": source_count,
        }

        for key, icon in NAVIGATION:
            label = self.t(f"nav.{key}")
            if key == "settings" or self._compact_sidebar:
                text = f"{icon}   {label}"
            else:
                text = f"{icon}   {label}   {counts.get(key, 0)}"
            self.nav_buttons[key].configure(text=text)

    def _update_nav_styles(self) -> None:
        for key, button in self.nav_buttons.items():
            active = key == self.active_view
            button.configure(
                fg_color=theme.ACCENT_SOFT if active else "transparent",
                hover_color=theme.ACCENT_SOFT if active else theme.SURFACE_SUBTLE,
                text_color=theme.ACCENT if active else theme.TEXT_SECONDARY,
                font=theme.font(13, "bold" if active else "normal"),
            )

    def _update_header_copy(self) -> None:
        self.view_title_label.configure(text=self.t(f"view.{self.active_view}.title"))
        self.view_subtitle_label.configure(
            text=self._header_subtitle(self.active_view)
        )

    def _header_subtitle(self, view: str) -> str:
        description = self.t(f"view.{view}.description")
        if view != "all":
            return description
        current = datetime.now()
        if current.hour < 12:
            greeting = self.t("greeting.morning")
        elif current.hour < 18:
            greeting = self.t("greeting.afternoon")
        else:
            greeting = self.t("greeting.evening")
        if self.language == "zh":
            date_text = f"{current.month}月{current.day}日"
        else:
            date_text = current.strftime("%A, %B %d").replace(" 0", " ")
        return f"{greeting} · {date_text} · {description}"

    def _selected_status_filter(self) -> str:
        selected_label = self.status_filter.get()
        for value, label in self._status_labels().items():
            if label == selected_label:
                return value
        return "all"

    def _selected_parser_mode(self) -> str:
        selected = self.parser_mode_menu.get().strip()
        if selected == self.t("parser.rule"):
            return "rule"
        if selected == self.t("parser.ai"):
            return "ai"
        return "auto"

    def _change_appearance(self, value: str) -> None:
        self.appearance_preference = value
        ctk.set_appearance_mode(value)

    def _change_language(self, value: str) -> None:
        language = next(
            (key for key, label in localization.LANGUAGE_NAMES.items() if label == value),
            self.language,
        )
        if language == self.language:
            return
        interface_state = {
            "search": self.search_entry.get(),
            "status": self._selected_status_filter(),
            "course": self.course_filter.get(),
            "parser": self._selected_parser_mode(),
        }
        self.language = language
        localization.save_language(language)
        self.title(self.t("app.title"))
        self._rebuild_interface(interface_state)

    def _rebuild_interface(self, interface_state: dict[str, str] | None = None) -> None:
        state = interface_state or {
            "search": "",
            "status": "all",
            "course": "",
            "parser": "auto",
        }
        self._cancel_pending_renders()
        for child in self.winfo_children():
            child.destroy()
        self.metric_cards = {}
        self.nav_buttons = {}
        self.settings_panel = None
        self.grid_rowconfigure(0, weight=1)
        self.grid_columnconfigure(1, weight=1)
        self._build_sidebar()
        self._build_workspace()
        self.search_entry.insert(0, state["search"])
        self.status_filter.set(self._status_labels()[state["status"]])
        self._update_course_filter()
        if state["course"] in self.course_filter.cget("values"):
            self.course_filter.set(state["course"])
        parser_labels = {
            "auto": self.t("parser.auto"),
            "ai": self.t("parser.ai"),
            "rule": self.t("parser.rule"),
        }
        self.parser_mode_menu.set(parser_labels[state["parser"]])
        self._update_summary()
        self._update_nav_badges()
        self._update_header_copy()
        if self.active_view == "settings":
            self._show_settings()
        else:
            self.render_assignments()
        if self.service_online is False:
            self.connection_dot.configure(text_color=theme.DANGER)
            self.connection_label.configure(text=self.t("connection.offline"))
            self.status_label.configure(text=self.t("status.unavailable"))
        elif self.service_online is True:
            self.connection_dot.configure(text_color=theme.SUCCESS)
            self.connection_label.configure(text=self.t("connection.online"))
            self.status_label.configure(
                text=self.t("status.updated", count=len(self.all_assignments))
            )

    def _change_motion(self) -> None:
        self.motion_enabled = bool(self.motion_switch.get())

    def _cancel_pending_renders(self) -> None:
        for after_id in self._render_after_ids:
            try:
                self.after_cancel(after_id)
            except TclError:
                pass
        self._render_after_ids.clear()

    def _fade_window(self, step: int = 0) -> None:
        steps = 10
        try:
            self.attributes("-alpha", min(1.0, step / steps))
        except TclError:
            return
        if step < steps:
            self.after(22, lambda: self._fade_window(step + 1))

    def _handle_resize(self, event: Any) -> None:
        if event.widget is not self:
            return
        compact = event.width < 1080
        if compact == self._compact_sidebar:
            return
        self._compact_sidebar = compact
        width = 190 if compact else 224
        self.sidebar.configure(width=width)
        self.grid_columnconfigure(0, minsize=width)
        self.brand_subtitle.configure(text="" if compact else self.t("brand.subtitle"))
        self._update_nav_badges()


def main() -> None:
    ctk.set_appearance_mode("System")
    ctk.set_default_color_theme("blue")
    app = AssignmentApp()
    app.mainloop()


if __name__ == "__main__":
    main()
