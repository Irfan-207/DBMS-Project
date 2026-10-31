from datetime import date, time
from decimal import Decimal
from pathlib import Path
import sys

import pytest
from pydantic import ValidationError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from app.schemas import (  # noqa: E402
    CourseCreate,
    EnrollmentCreate,
    InvoiceCreate,
    PaymentCreate,
    ScheduleCreate,
    StudentCreate,
    StudentUpdate,
    TeacherCreate,
)


def test_student_discount_accepts_valid_percentage():
    item = StudentCreate(
        student_code="STU-TEST",
        full_name="Demo Student",
        discount_rate=Decimal("12.5"),
    )
    assert item.discount_rate == Decimal("12.5")


@pytest.mark.parametrize("rate", [-1, 100.01])
def test_student_discount_rejects_out_of_range(rate):
    with pytest.raises(ValidationError):
        StudentCreate(student_code="STU-TEST", full_name="Demo Student", discount_rate=rate)


def test_optional_student_email_is_normalized_to_none():
    item = StudentCreate(student_code="STU-TEST", full_name="Demo Student", email="   ")
    assert item.email is None


def test_teacher_account_requires_login_email_and_long_password():
    with pytest.raises(ValidationError):
        TeacherCreate(full_name="Demo Teacher", email="   ", password="long-enough-password")


def test_student_update_accepts_partial_fields():
    update = StudentUpdate(full_name="Updated Student")
    assert update.model_dump(exclude_unset=True) == {"full_name": "Updated Student"}

    with pytest.raises(ValidationError):
        StudentUpdate(full_name=None)


def test_course_fee_and_capacity_schema():
    item = CourseCreate(
        title="Physics Batch",
        course_type="regular",
        fee_type="monthly",
        fee_amount=Decimal("1500"),
        start_date=date(2026, 10, 1),
        seat_capacity=25,
        teacher_id=1,
        subject_id=1,
    )
    assert item.fee_amount == Decimal("1500")
    assert item.seat_capacity == 25


def test_course_rejects_incompatible_fee_type():
    with pytest.raises(ValidationError):
        CourseCreate(
            title="Physics Batch",
            course_type="regular",
            fee_type="one_time",
            fee_amount=Decimal("1500"),
            start_date=date(2026, 10, 1),
            seat_capacity=25,
            teacher_id=1,
            subject_id=1,
        )


def test_enrollment_requires_positive_ids():
    assert EnrollmentCreate(student_id=1, course_id=2).course_id == 2
    with pytest.raises(ValidationError):
        EnrollmentCreate(student_id=0, course_id=2)


def test_schedule_requires_positive_duration():
    with pytest.raises(ValidationError):
        ScheduleCreate(day_of_week=1, start_time=time(10), end_time=time(10))


def test_invoice_rejects_reversed_period():
    with pytest.raises(ValidationError):
        InvoiceCreate(
            enrollment_id=1,
            period_start=date(2026, 10, 2),
            period_end=date(2026, 10, 1),
            due_date=date(2026, 10, 5),
        )


def test_payment_must_be_positive_and_use_supported_method():
    with pytest.raises(ValidationError):
        PaymentCreate(amount=Decimal("0"), payment_method="cash")
    with pytest.raises(ValidationError):
        PaymentCreate(amount=Decimal("1"), payment_method="cheque")
