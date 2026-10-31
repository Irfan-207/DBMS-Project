import os
from pathlib import Path
import re
import sys

import pytest
from fastapi import HTTPException
from starlette.requests import Request

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
os.environ.setdefault("DATABASE_URL", "sqlite://")

from app.main import AuthContext, api, app, require_admin, require_csrf  # noqa: E402


def route_dependencies(route):
    return {dependency.call for dependency in route.dependant.dependencies}


def test_every_api_router_route_requires_session_and_csrf():
    assert api.routes
    for route in api.routes:
        assert require_csrf in route_dependencies(route), route.path


def test_sensitive_management_routes_are_admin_only():
    admin_routes = {
        (route.path, method)
        for route in api.routes
        if require_admin in route_dependencies(route)
        for method in route.methods
    }
    expected = {
        ("/api/students", "GET"),
        ("/api/students", "POST"),
        ("/api/students/{student_id}", "PATCH"),
        ("/api/students/{student_id}/status", "PATCH"),
        ("/api/students/{student_id}/account", "PUT"),
        ("/api/teachers", "GET"),
        ("/api/teachers", "POST"),
        ("/api/teachers/{teacher_id}", "PATCH"),
        ("/api/teachers/{teacher_id}/status", "PATCH"),
        ("/api/teachers/{teacher_id}/account", "PUT"),
        ("/api/subjects", "POST"),
        ("/api/subjects/{subject_id}", "PATCH"),
        ("/api/courses", "POST"),
        ("/api/courses/{course_id}", "PATCH"),
        ("/api/courses/{course_id}/status", "PATCH"),
        ("/api/enrollments", "POST"),
        ("/api/enrollments/{enrollment_id}", "PATCH"),
        ("/api/courses/{course_id}/schedules", "POST"),
        ("/api/schedules/{schedule_id}", "PATCH"),
        ("/api/courses/{course_id}/exams", "POST"),
        ("/api/exams/{exam_id}", "PATCH"),
        ("/api/invoices", "POST"),
        ("/api/invoices/{invoice_id}/payments", "POST"),
        ("/api/reports/outstanding-dues", "GET"),
        ("/api/reports/course-revenue", "GET"),
    }
    assert expected <= admin_routes


def test_login_is_the_only_public_api_route():
    public_api_paths = {
        route.path
        for route in app.routes
        if getattr(route, "path", "").startswith("/api/")
    }
    assert public_api_paths == {"/api/auth/login"}


def test_frontend_api_paths_exist_in_backend_routes():
    root = Path(__file__).resolve().parents[1]
    frontend_sources = [
        root / "frontend" / "src" / "App.tsx",
        root / "frontend" / "src" / "auth.tsx",
    ]
    frontend_paths = set()
    for source in frontend_sources:
        contents = source.read_text(encoding="utf-8")
        for path in re.findall(r"""(/api/[^`'"\s]+)""", contents):
            frontend_paths.add(re.sub(r"\$\{[^}]+\}", "1", path.split("?", 1)[0]))

    backend_paths = {
        re.sub(r"\{[^}]+\}", "1", route.path)
        for route in [*api.routes, *app.routes]
        if getattr(route, "path", "").startswith("/api/")
    }
    assert frontend_paths
    assert frontend_paths <= backend_paths


def test_teacher_cannot_pass_admin_guard():
    teacher = type("User", (), {"role": "teacher"})()
    context = AuthContext(user=teacher, session=object())
    with pytest.raises(HTTPException) as error:
        require_admin(context)
    assert error.value.status_code == 403


def test_csrf_guard_rejects_missing_or_mismatched_token():
    request = Request(
        {
            "type": "http",
            "method": "POST",
            "path": "/api/students",
            "headers": [],
            "query_string": b"",
            "server": ("testserver", 80),
            "client": ("testclient", 123),
            "scheme": "http",
        }
    )
    context = AuthContext(
        user=type("User", (), {"role": "admin"})(),
        session=type("Session", (), {"csrf_token": "expected-token"})(),
    )
    with pytest.raises(HTTPException) as error:
        require_csrf(request, context)
    assert error.value.status_code == 403
