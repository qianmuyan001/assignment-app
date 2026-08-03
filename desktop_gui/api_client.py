from __future__ import annotations

import os
from typing import Any

import requests


BASE_URL = os.getenv("ASSIGNMENT_API_BASE_URL", "http://127.0.0.1:8000").rstrip("/")
TIMEOUT_SECONDS = 10


class ApiError(Exception):
    def __init__(self, message: str, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


def get_assignments() -> list[dict[str, Any]]:
    data = _request("GET", "/assignments")
    if not isinstance(data, list):
        raise ApiError("The backend returned assignment data in an unexpected format.")
    return data


def create_assignment(data: dict[str, Any]) -> dict[str, Any]:
    result = _request("POST", "/assignments", json=data)
    if not isinstance(result, dict):
        raise ApiError("The backend did not return the created assignment.")
    return result


def update_assignment(assignment_id: int, data: dict[str, Any]) -> dict[str, Any]:
    try:
        result = _request("PUT", f"/assignments/{assignment_id}", json=data)
    except ApiError as error:
        if error.status_code != 405:
            raise
        result = _request("PATCH", f"/assignments/{assignment_id}", json=data)

    if not isinstance(result, dict):
        raise ApiError("The backend did not return the updated assignment.")
    return result


def delete_assignment(assignment_id: int) -> None:
    _request("DELETE", f"/assignments/{assignment_id}")


def mark_assignment_complete(assignment_id: int) -> dict[str, Any]:
    try:
        result = _request(
            "PATCH",
            f"/assignments/{assignment_id}/status",
            json={"status": "completed"},
        )
    except ApiError as error:
        if error.status_code != 422:
            raise
        result = _request(
            "PATCH",
            f"/assignments/{assignment_id}/status",
            json={"status": "done"},
        )

    if not isinstance(result, dict):
        raise ApiError("The backend did not return the updated assignment.")
    return result


def _request(method: str, path: str, **kwargs: Any) -> Any:
    url = f"{BASE_URL}{path}"

    try:
        response = requests.request(method, url, timeout=TIMEOUT_SECONDS, **kwargs)
    except requests.ConnectionError as error:
        raise ApiError(
            f"Could not connect to the backend at {BASE_URL}. Start the FastAPI backend first."
        ) from error
    except requests.Timeout as error:
        raise ApiError("The backend took too long to respond. Please try again.") from error
    except requests.RequestException as error:
        raise ApiError(f"The backend request failed: {error}") from error

    if not response.ok:
        raise ApiError(_error_message_from_response(response), response.status_code)

    if response.status_code == 204:
        return None

    try:
        return response.json()
    except ValueError as error:
        raise ApiError("The backend returned a response that was not valid JSON.") from error


def _error_message_from_response(response: requests.Response) -> str:
    fallback = f"Backend error {response.status_code}. Please try again."

    try:
        body = response.json()
    except ValueError:
        return response.text.strip() or fallback

    detail = body.get("detail") if isinstance(body, dict) else None

    if isinstance(detail, str):
        return detail

    if isinstance(detail, list):
        messages = []
        for item in detail:
            if isinstance(item, dict):
                location = " -> ".join(str(part) for part in item.get("loc", []))
                message = item.get("msg", "Invalid value")
                messages.append(f"{location}: {message}" if location else message)
        if messages:
            return "\n".join(messages)

    return fallback

