from __future__ import annotations

import platform
from tkinter import TclError
from typing import TypeAlias

import customtkinter as ctk


Color: TypeAlias = str | tuple[str, str]


# CustomTkinter cannot apply a browser-style backdrop-filter to individual widgets.
# These adaptive, low-contrast surfaces recreate the same visual hierarchy while
# remaining fast and predictable on both macOS and Windows.
WINDOW: Color = ("#EEF2F7", "#0B0D12")
SIDEBAR: Color = ("#E7ECF3", "#11141A")
SURFACE: Color = ("#F9FBFD", "#171B22")
SURFACE_RAISED: Color = ("#FFFFFF", "#1B2029")
SURFACE_SUBTLE: Color = ("#F0F4F8", "#202630")
SURFACE_HOVER: Color = ("#FFFFFF", "#202731")
INPUT: Color = ("#F2F5F9", "#20252E")

BORDER: Color = ("#DCE2EA", "#2A303A")
BORDER_STRONG: Color = ("#C9D1DD", "#3A424F")
BORDER_ACTIVE: Color = ("#A9CFF9", "#315E8B")

TEXT_PRIMARY: Color = ("#17191D", "#F5F7FA")
TEXT_SECONDARY: Color = ("#646D7A", "#AAB2BF")
TEXT_TERTIARY: Color = ("#88919E", "#7E8794")

ACCENT = "#0A84FF"
ACCENT_HOVER = "#0071E3"
ACCENT_PRESSED = "#0066CC"
ACCENT_SOFT: Color = ("#E5F2FF", "#122C46")

SUCCESS = "#30A46C"
SUCCESS_HOVER = "#278B5D"
SUCCESS_SOFT: Color = ("#E7F7EE", "#163226")

WARNING = "#C87500"
WARNING_SOFT: Color = ("#FFF2D7", "#3A2B12")

DANGER = "#E5484D"
DANGER_HOVER = "#CC3E43"
DANGER_SOFT: Color = ("#FDEBEC", "#3B1E22")

PURPLE = "#7C5CFC"
PURPLE_SOFT: Color = ("#EFEAFF", "#29213F")

DISABLED: Color = ("#B8C0CB", "#4A515C")
TRANSPARENT = "transparent"


def font_family() -> str:
    system = platform.system()
    if system == "Darwin":
        return "SF Pro Display"
    if system == "Windows":
        return "Segoe UI"
    return "Inter"


def font(size: int, weight: str = "normal") -> ctk.CTkFont:
    return ctk.CTkFont(family=font_family(), size=size, weight=weight)


def resolved(color: Color) -> str:
    if isinstance(color, tuple):
        return color[1] if ctk.get_appearance_mode() == "Dark" else color[0]
    return color


def blend(first: str, second: str, amount: float) -> str:
    """Blend two #RRGGBB colors for lightweight hover/exit animations."""
    amount = max(0.0, min(1.0, amount))
    first_rgb = tuple(int(first[index : index + 2], 16) for index in (1, 3, 5))
    second_rgb = tuple(int(second[index : index + 2], 16) for index in (1, 3, 5))
    mixed = tuple(
        round(first_value + (second_value - first_value) * amount)
        for first_value, second_value in zip(first_rgb, second_rgb)
    )
    return "#{:02X}{:02X}{:02X}".format(*mixed)


def bind_focus_ring(
    widget: ctk.CTkBaseClass,
    event_target: object | None = None,
) -> None:
    """Add a short animated Apple-blue focus ring to an input control."""
    target = event_target or widget
    animation_id: str | None = None
    current = resolved(BORDER)

    def animate(destination: str) -> None:
        nonlocal animation_id, current
        if animation_id:
            try:
                widget.after_cancel(animation_id)
            except TclError:
                pass

        start = current
        steps = 5

        def frame(step: int) -> None:
            nonlocal animation_id, current
            try:
                current = blend(start, destination, step / steps)
                widget.configure(border_color=current)
            except TclError:
                return
            if step < steps:
                animation_id = widget.after(18, lambda: frame(step + 1))
            else:
                animation_id = None

        frame(1)

    target.bind("<FocusIn>", lambda _event: animate(ACCENT), add="+")
    target.bind("<FocusOut>", lambda _event: animate(resolved(BORDER)), add="+")
