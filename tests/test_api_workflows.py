from decimal import Decimal
from pathlib import Path
import sys
from types import SimpleNamespace

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from app import models  # noqa: E402
from app.auth import hash_password, verify_password  # noqa: E402
from app.database import Base  # noqa: E402
from app.main import (
    AuthContext,
    api,
    get_current_user,
    get_db,
    list_exams,
    list_results,
    list_schedules,
    list_teacher_subjects,
    login,
    performance,
    require_csrf,
    top_students,
)  # noqa: E402


class APIWorkflow:
    def __init__(self, client, context, session_factory):
        self.client = client
        self.context = context
        self.session_factory = session_factory

    def create_subject(self, name="Mathematics"):
        response = self.client.post("/api/subjects", json={"name": name})
        assert response.status_code == 201, response.text
        return response.json()

    def create_teacher(self, email="teacher@example.com", subject_ids=None):
        response = self.client.post(
            "/api/teachers",
            json={
                "full_name": "Workflow Teacher",
                "email": email,
                "password": "a-strong-password",
                "subject_ids": subject_ids or [],
            },
        )
        return response

    def create_student(self, student_code="STU-001", discount_rate=0):
        response = self.client.post(
            "/api/students",
            json={
                "student_code": student_code,
                "full_name": f"Student {student_code}",
                "discount_rate": discount_rate,
            },
        )
        assert response.status_code == 201, response.text
        return response.json()

    def create_course(self, teacher_id, subject_id, *, title="Course", fee_amount=100, capacity=2):
        response = self.client.post(
            "/api/courses",
            json={
                "title": title,
                "course_type": "special",
                "fee_type": "one_time",
                "fee_amount": fee_amount,
                "start_date": "2026-10-01",
                "seat_capacity": capacity,
                "teacher_id": teacher_id,
                "subject_id": subject_id,
            },
        )
        assert response.status_code == 201, response.text
        return response.json()


def _session_context(role="admin", teacher_id=None, student_id=None):
    user = SimpleNamespace(role=role, teacher_id=teacher_id, student_id=student_id, id=1)
    session = SimpleNamespace(csrf_token="test-csrf")
    return AuthContext(user=user, session=session)


class _CapturedQuery:
    def mappings(self):
        return self

    def all(self):
        return []


class _CapturingDB:
    def execute(self, statement, params=None):
        self.statement = str(statement)
        self.params = params or {}
        return _CapturedQuery()


@pytest.mark.parametrize(
    "endpoint",
    [performance, list_schedules, list_exams, list_results, top_students, list_teacher_subjects],
)
@pytest.mark.parametrize(("role", "teacher_id"), [("admin", None), ("teacher", 7)])
def test_teacher_scoped_queries_only_bind_teacher_id_for_teachers(endpoint, role, teacher_id):
    db = _CapturingDB()

    endpoint(context=_session_context(role, teacher_id), db=db)

    if role == "teacher":
        teacher_column = "ts.teacher_id" if endpoint is list_teacher_subjects else "c.teacher_id"
        assert f"WHERE {teacher_column} = :teacher_id" in db.statement
        assert db.params["teacher_id"] == teacher_id
    else:
        assert ":teacher_id" not in db.statement
        assert "teacher_id" not in db.params


def _make_client():
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    session_factory = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)

    def get_test_db():
        db = session_factory()
        try:
            yield db
        finally:
            db.close()

    context = {"current": _session_context()}
    test_app = FastAPI()
    test_app.include_router(api)
    test_app.add_api_route("/api/auth/login", login, methods=["POST"])
    test_app.dependency_overrides[get_db] = get_test_db
    test_app.dependency_overrides[get_current_user] = lambda: context["current"]
    test_app.dependency_overrides[require_csrf] = lambda: None
    return engine, session_factory, context, TestClient(test_app)


def test_teacher_creation_assigns_subjects_atomically():
    engine, session_factory, context, client = _make_client()
    try:
        with client:
            flow = APIWorkflow(client, context, session_factory)
            subject = flow.create_subject()
            teacher_response = flow.create_teacher(subject_ids=[subject["id"]])
            assert teacher_response.status_code == 201, teacher_response.text
            teacher = teacher_response.json()
            assignments = client.get("/api/teacher-subjects").json()
            assert [(item["teacher_id"], item["subject_id"]) for item in assignments] == [
                (teacher["id"], subject["id"])
            ]

            duplicate_email = flow.create_teacher(email="teacher@example.com", subject_ids=[subject["id"]])
            assert duplicate_email.status_code == 409
            assert len(client.get("/api/teachers").json()) == 1

            invalid_subject = flow.create_teacher(email="other@example.com", subject_ids=[999])
            assert invalid_subject.status_code == 422
            assert len(client.get("/api/teachers").json()) == 1
    finally:
        engine.dispose()


def test_admin_teacher_and_student_accounts_are_scoped_and_login_by_role():
    engine, session_factory, context, client = _make_client()
    try:
        with client:
            flow = APIWorkflow(client, context, session_factory)
            subject = flow.create_subject()
            teacher = flow.create_teacher("teacher-one@example.com", [subject["id"]]).json()
            other_teacher = flow.create_teacher("teacher-two@example.com", [subject["id"]]).json()
            student = flow.create_student("STU-ACCOUNT-1")
            other_student = flow.create_student("STU-ACCOUNT-2")
            own_course = flow.create_course(teacher["id"], subject["id"], title="Own course")
            other_course = flow.create_course(other_teacher["id"], subject["id"], title="Other course")

            own_enrollment = client.post(
                "/api/enrollments",
                json={"student_id": student["id"], "course_id": own_course["id"]},
            ).json()
            other_enrollment = client.post(
                "/api/enrollments",
                json={"student_id": other_student["id"], "course_id": other_course["id"]},
            ).json()
            for course, title in ((own_course, "Own exam"), (other_course, "Other exam")):
                schedule = client.post(
                    f"/api/courses/{course['id']}/schedules",
                    json={"day_of_week": 2, "start_time": "10:00", "end_time": "11:00"},
                )
                assert schedule.status_code == 201, schedule.text
                exam = client.post(
                    f"/api/courses/{course['id']}/exams",
                    json={"title": title, "exam_date": "2026-10-31", "total_marks": 100},
                )
                assert exam.status_code == 201, exam.text
                course["exam_id"] = exam.json()["id"]
            other_result = client.post(
                f"/api/exams/{other_course['exam_id']}/results",
                json={"student_id": other_student["id"], "marks_obtained": 70},
            )
            assert other_result.status_code == 201, other_result.text

            own_invoice = client.post(
                "/api/invoices",
                json={
                    "enrollment_id": own_enrollment["id"],
                    "period_start": "2026-10-01",
                    "due_date": "2026-10-31",
                },
            ).json()
            other_invoice = client.post(
                "/api/invoices",
                json={
                    "enrollment_id": other_enrollment["id"],
                    "period_start": "2026-10-01",
                    "due_date": "2026-10-31",
                },
            ).json()
            own_payment = client.post(
                f"/api/invoices/{own_invoice['id']}/payments",
                json={"amount": "10", "payment_method": "cash"},
            ).json()
            other_payment = client.post(
                f"/api/invoices/{other_invoice['id']}/payments",
                json={"amount": "10", "payment_method": "cash"},
            ).json()
            assert own_payment["status"] == other_payment["status"] == "partial"

            student_account = client.put(
                f"/api/students/{student['id']}/account",
                json={"email": "student-one@example.com", "password": "student-password-123"},
            )
            assert student_account.status_code == 200, student_account.text
            teacher_account = client.put(
                f"/api/teachers/{teacher['id']}/account",
                json={"password": "teacher-password-123"},
            )
            assert teacher_account.status_code == 200, teacher_account.text

            with session_factory() as db:
                student_user = db.scalar(
                    select(models.UserAccount).where(models.UserAccount.student_id == student["id"])
                )
                teacher_user = db.scalar(
                    select(models.UserAccount).where(models.UserAccount.teacher_id == teacher["id"])
                )
                assert student_user.role == "student"
                assert models.UserAccount.student_id.property.columns[0].nullable
                assert verify_password("student-password-123", student_user.password_hash)
                assert verify_password("teacher-password-123", teacher_user.password_hash)
                assert student_user.password_hash != "student-password-123"

            for email, password, role in (
                ("admin@example.com", "administrator-password-123", "admin"),
                ("teacher-one@example.com", "teacher-password-123", "teacher"),
                ("student-one@example.com", "student-password-123", "student"),
            ):
                if role == "admin":
                    with session_factory.begin() as db:
                        db.add(
                            models.UserAccount(
                                email=email,
                                password_hash=hash_password(password),
                                role="admin",
                            )
                        )
                response = client.post(
                    "/api/auth/login",
                    json={"email": email, "password": password, "role": role},
                )
                assert response.status_code == 200, response.text
                assert response.json()["role"] == role
                assert client.post(
                    "/api/auth/login",
                    json={"email": email, "password": password, "role": "student" if role != "student" else "teacher"},
                ).status_code == 401

            # Admin can still view both assigned and unassigned records.
            context["current"] = _session_context()
            assert len(client.get("/api/courses").json()) == 2
            assert len(client.get("/api/payments").json()) == 2

            context["current"] = _session_context("teacher", teacher["id"])
            assert [row["id"] for row in client.get("/api/courses").json()] == [own_course["id"]]
            assert [row["course_id"] for row in client.get("/api/schedules").json()] == [own_course["id"]]
            assert [row["id"] for row in client.get("/api/teacher/students").json()] == [student["id"]]
            own_result = client.post(
                f"/api/exams/{own_course['exam_id']}/results",
                json={"student_id": student["id"], "marks_obtained": 80},
            )
            assert own_result.status_code == 201, own_result.text
            assert client.post(
                f"/api/exams/{other_course['exam_id']}/results",
                json={"student_id": other_student["id"], "marks_obtained": 80},
            ).status_code == 403
            assert client.post(
                f"/api/exams/{own_course['exam_id']}/results",
                json={"student_id": other_student["id"], "marks_obtained": 80},
            ).status_code == 422
            assert client.patch(
                f"/api/results/{other_result.json()['id']}",
                json={"marks_obtained": 60},
            ).status_code == 403
            assert client.get("/api/students").status_code == 403
            assert client.get("/api/invoices").status_code == 403
            assert client.get("/api/payments").status_code == 403

            context["current"] = _session_context("student", student_id=student["id"])
            assert [row["id"] for row in client.get("/api/courses").json()] == [own_course["id"]]
            assert [row["student_id"] for row in client.get("/api/enrollments").json()] == [student["id"]]
            assert [row["student_id"] for row in client.get("/api/results").json()] == [student["id"]]
            assert all(row["student_id"] != other_student["id"] for row in client.get("/api/results").json())
            assert [row["id"] for row in client.get("/api/invoices").json()] == [own_invoice["id"]]
            assert [row["id"] for row in client.get("/api/payments").json()] == [own_payment["payment_id"]]
            assert client.get("/api/students").status_code == 403
            assert client.get("/api/schedules").status_code == 403
            assert client.get("/api/exams").status_code == 403
            assert client.get("/api/reports/top-students").status_code == 403
            assert client.post(
                f"/api/exams/{own_course['exam_id']}/results",
                json={"student_id": student["id"], "marks_obtained": 50},
            ).status_code == 403
            assert client.patch(
                f"/api/results/{own_result.json()['id']}",
                json={"marks_obtained": 60},
            ).status_code == 403
    finally:
        engine.dispose()


def test_enrollment_capacity_and_reactivation_are_enforced():
    engine, session_factory, context, client = _make_client()
    try:
        with client:
            flow = APIWorkflow(client, context, session_factory)
            subject = flow.create_subject()
            teacher = flow.create_teacher().json()
            course = flow.create_course(teacher["id"], subject["id"], capacity=2)
            first = flow.create_student("STU-001")
            second = flow.create_student("STU-002")
            third = flow.create_student("STU-003")

            enrolled = client.post(
                "/api/enrollments",
                json={"student_id": first["id"], "course_id": course["id"]},
            )
            assert enrolled.status_code == 201, enrolled.text
            second_enrollment = client.post(
                "/api/enrollments",
                json={"student_id": second["id"], "course_id": course["id"]},
            )
            assert second_enrollment.status_code == 201, second_enrollment.text
            full = client.post(
                "/api/enrollments",
                json={"student_id": third["id"], "course_id": course["id"]},
            )
            assert full.status_code == 409

            enrollment_id = enrolled.json()["id"]
            assert client.patch(f"/api/enrollments/{enrollment_id}?status=dropped").status_code == 200
            third_enrollment = client.post(
                "/api/enrollments",
                json={"student_id": third["id"], "course_id": course["id"]},
            )
            assert third_enrollment.status_code == 201, third_enrollment.text
            reactivated = client.patch(f"/api/enrollments/{enrollment_id}?status=active")
            assert reactivated.status_code == 409

            too_small = client.patch(
                f"/api/courses/{course['id']}",
                json={
                    "title": "Updated course",
                    "course_type": "special",
                    "fee_type": "one_time",
                    "fee_amount": 100,
                    "start_date": "2026-10-01",
                    "seat_capacity": 1,
                    "teacher_id": teacher["id"],
                    "subject_id": subject["id"],
                },
            )
            assert too_small.status_code == 409
    finally:
        engine.dispose()


def test_schedule_conflicts_and_payment_balance_are_rejected():
    engine, session_factory, context, client = _make_client()
    try:
        with client:
            flow = APIWorkflow(client, context, session_factory)
            subject = flow.create_subject()
            teacher = flow.create_teacher().json()
            first_course = flow.create_course(teacher["id"], subject["id"], title="First")
            second_course = flow.create_course(teacher["id"], subject["id"], title="Second")
            first_schedule = client.post(
                f"/api/courses/{first_course['id']}/schedules",
                json={"day_of_week": 1, "start_time": "10:00", "end_time": "11:00"},
            )
            assert first_schedule.status_code == 201, first_schedule.text
            conflict = client.post(
                f"/api/courses/{second_course['id']}/schedules",
                json={"day_of_week": 1, "start_time": "10:30", "end_time": "11:30"},
            )
            assert conflict.status_code == 409

            student = flow.create_student("STU-003", discount_rate=10)
            enrollment = client.post(
                "/api/enrollments",
                json={"student_id": student["id"], "course_id": first_course["id"]},
            )
            assert enrollment.status_code == 201, enrollment.text
            invoice = client.post(
                "/api/invoices",
                json={
                    "enrollment_id": enrollment.json()["id"],
                    "period_start": "2026-10-01",
                    "due_date": "2026-10-31",
                },
            )
            assert invoice.status_code == 201, invoice.text
            assert Decimal(str(invoice.json()["discount_amount"])) == Decimal("10.00")
            assert Decimal(str(invoice.json()["amount_due"])) == Decimal("90.00")
            with session_factory() as db:
                invoice_row = db.get(models.Invoice, invoice.json()["id"])
                invoice_row.amount_due = Decimal("91.00")
                with pytest.raises(IntegrityError):
                    db.commit()
                db.rollback()

            invoice_id = invoice.json()["id"]
            partial = client.post(
                f"/api/invoices/{invoice_id}/payments",
                json={"amount": "50", "payment_method": "cash"},
            )
            assert partial.status_code == 201, partial.text
            overpayment = client.post(
                f"/api/invoices/{invoice_id}/payments",
                json={"amount": "40.01", "payment_method": "cash"},
            )
            assert overpayment.status_code == 422
            final = client.post(
                f"/api/invoices/{invoice_id}/payments",
                json={"amount": "40", "payment_method": "cash"},
            )
            assert final.status_code == 201, final.text
            assert final.json()["status"] == "paid"
    finally:
        engine.dispose()


def test_admin_can_edit_supported_management_records():
    engine, session_factory, context, client = _make_client()
    try:
        with client:
            flow = APIWorkflow(client, context, session_factory)
            subject = flow.create_subject()
            teacher = flow.create_teacher(subject_ids=[subject["id"]]).json()
            student = flow.create_student("STU-EDIT")
            course = flow.create_course(teacher["id"], subject["id"])
            enrollment = client.post(
                "/api/enrollments",
                json={"student_id": student["id"], "course_id": course["id"]},
            ).json()
            schedule = client.post(
                f"/api/courses/{course['id']}/schedules",
                json={"day_of_week": 1, "start_time": "10:00", "end_time": "11:00"},
            ).json()
            exam = client.post(
                f"/api/courses/{course['id']}/exams",
                json={"title": "Original exam", "exam_date": "2026-10-31", "total_marks": 100},
            ).json()

            assert client.patch(
                f"/api/students/{student['id']}",
                json={"full_name": "Edited student"},
            ).json()["full_name"] == "Edited student"
            edited_teacher = client.patch(
                f"/api/teachers/{teacher['id']}",
                json={
                    "full_name": "Edited teacher",
                    "email": "edited@example.com",
                    "subject_ids": [],
                },
            )
            assert edited_teacher.status_code == 200, edited_teacher.text
            assert edited_teacher.json()["email"] == "edited@example.com"
            with session_factory() as db:
                account = db.scalar(
                    select(models.UserAccount).where(models.UserAccount.teacher_id == teacher["id"])
                )
                assert account.email == "edited@example.com"
                assert db.scalars(
                    select(models.TeacherSubject).where(models.TeacherSubject.teacher_id == teacher["id"])
                ).all() == []

            assert client.patch(
                f"/api/subjects/{subject['id']}",
                json={"name": "Updated subject"},
            ).json()["name"] == "Updated subject"
            edited_course = client.patch(
                f"/api/courses/{course['id']}",
                json={"title": "Edited course"},
            )
            assert edited_course.status_code == 200, edited_course.text
            assert edited_course.json()["title"] == "Edited course"
            edited_schedule = client.patch(
                f"/api/schedules/{schedule['id']}",
                json={"start_time": "11:00", "end_time": "12:00"},
            )
            assert edited_schedule.status_code == 200, edited_schedule.text
            edited_exam = client.patch(
                f"/api/exams/{exam['id']}",
                json={"title": "Edited exam"},
            )
            assert edited_exam.status_code == 200, edited_exam.text
            assert edited_exam.json()["title"] == "Edited exam"
            assert enrollment["course_id"] == course["id"]
    finally:
        engine.dispose()


def test_teacher_course_scope_applies_to_reads_and_result_updates():
    engine, session_factory, context, client = _make_client()
    try:
        with client:
            flow = APIWorkflow(client, context, session_factory)
            subject = flow.create_subject()
            teacher = flow.create_teacher(email="owner@example.com").json()
            other_teacher = flow.create_teacher(email="other@example.com").json()
            own_course = flow.create_course(teacher["id"], subject["id"], title="Own course")
            other_course = flow.create_course(other_teacher["id"], subject["id"], title="Other course")
            student = flow.create_student("STU-004")
            own_enrollment = client.post(
                "/api/enrollments",
                json={"student_id": student["id"], "course_id": own_course["id"]},
            ).json()
            other_student = flow.create_student("STU-005")
            client.post(
                "/api/enrollments",
                json={"student_id": other_student["id"], "course_id": other_course["id"]},
            )
            own_exam = client.post(
                f"/api/courses/{own_course['id']}/exams",
                json={"title": "Own exam", "exam_date": "2026-10-31", "total_marks": 100},
            ).json()
            other_exam = client.post(
                f"/api/courses/{other_course['id']}/exams",
                json={"title": "Other exam", "exam_date": "2026-10-31", "total_marks": 100},
            ).json()
            other_result = client.post(
                f"/api/exams/{other_exam['id']}/results",
                json={"student_id": other_student["id"], "marks_obtained": 50},
            ).json()
            own_result = client.post(
                f"/api/exams/{own_exam['id']}/results",
                json={"student_id": student["id"], "marks_obtained": 80},
            ).json()
            assert own_result["id"] != other_result["id"]
            for course_id, start_time in (
                (own_course["id"], "10:00"),
                (other_course["id"], "12:00"),
            ):
                schedule = client.post(
                    f"/api/courses/{course_id}/schedules",
                    json={"day_of_week": 2, "start_time": start_time, "end_time": "13:00"},
                )
                assert schedule.status_code == 201, schedule.text
            context["current"] = _session_context("teacher", teacher["id"])

            assert [course["id"] for course in client.get("/api/courses").json()] == [own_course["id"]]
            assert [item["course_id"] for item in client.get("/api/enrollments").json()] == [own_course["id"]]
            assert [exam["id"] for exam in client.get("/api/exams").json()] == [own_exam["id"]]
            assert [result["id"] for result in client.get("/api/results").json()] == [own_result["id"]]
            assert {schedule["course_id"] for schedule in client.get("/api/schedules").json()} == {own_course["id"]}
            assert client.get(f"/api/teachers/{other_teacher['id']}/schedule").status_code == 403
            forbidden = client.post(
                f"/api/exams/{other_exam['id']}/results",
                json={"student_id": other_student["id"], "marks_obtained": 50},
            )
            assert forbidden.status_code == 403
            updated = client.patch(
                f"/api/results/{own_result['id']}",
                json={"marks_obtained": 90, "remarks": "Updated"},
            )
            assert updated.status_code == 200, updated.text
            assert Decimal(str(updated.json()["marks_obtained"])) == Decimal("90.00")
            forbidden_result_update = client.patch(
                f"/api/results/{other_result['id']}",
                json={"marks_obtained": 60},
            )
            assert forbidden_result_update.status_code == 403
            context["current"] = _session_context()
            invalid_exam_edit = client.patch(
                f"/api/exams/{own_exam['id']}",
                json={"title": "Own exam", "exam_date": "2026-10-31", "total_marks": 89},
            )
            assert invalid_exam_edit.status_code == 409
            assert own_enrollment["course_id"] == own_course["id"]
    finally:
        engine.dispose()
