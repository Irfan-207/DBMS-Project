from datetime import date, time
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator, model_validator


class InputModel(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=256)
    role: Literal["admin", "teacher", "student"] | None = None

    @field_validator("email", mode="before")
    @classmethod
    def normalize_email(cls, value):
        return value.strip() if isinstance(value, str) else value


class TeacherAccountCreate(BaseModel):
    password: str = Field(min_length=12, max_length=256)
    email: EmailStr | None = None

    @field_validator("email", mode="before")
    @classmethod
    def empty_email_is_none(cls, value):
        return value.strip() or None if isinstance(value, str) else value


class StudentAccountCreate(BaseModel):
    email: EmailStr
    password: str = Field(min_length=12, max_length=256)

    @field_validator("email", mode="before")
    @classmethod
    def normalize_email(cls, value):
        return value.strip() if isinstance(value, str) else value


class PasswordChange(BaseModel):
    current_password: str = Field(min_length=1, max_length=256)
    new_password: str = Field(min_length=12, max_length=256)


class ORM(BaseModel):
    model_config = ConfigDict(from_attributes=True)


class StudentCreate(InputModel):
    student_code: str = Field(min_length=2, max_length=30)
    full_name: str = Field(min_length=2, max_length=120)
    email: EmailStr | None = None
    phone: str | None = Field(default=None, max_length=30)
    guardian_name: str | None = Field(default=None, max_length=120)
    guardian_phone: str | None = Field(default=None, max_length=30)
    discount_rate: Decimal = Field(default=Decimal("0"), ge=0, le=100, max_digits=5, decimal_places=2)

    @field_validator("email", mode="before")
    @classmethod
    def empty_email_is_none(cls, value):
        return value.strip() or None if isinstance(value, str) else value


class StudentUpdate(StudentCreate):
    student_code: str | None = Field(default=None, min_length=2, max_length=30)
    full_name: str | None = Field(default=None, min_length=2, max_length=120)
    discount_rate: Decimal | None = Field(default=None, ge=0, le=100, max_digits=5, decimal_places=2)

    @model_validator(mode="after")
    def reject_null_required_fields(self):
        for field in ("student_code", "full_name", "discount_rate"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null.")
        return self


class StudentOut(ORM):
    id: int
    student_code: str
    full_name: str
    email: str | None
    phone: str | None
    guardian_name: str | None
    guardian_phone: str | None
    discount_rate: Decimal
    is_active: bool


class TeacherCreate(BaseModel):
    full_name: str = Field(min_length=2, max_length=120)
    email: EmailStr
    phone: str | None = Field(default=None, max_length=30)
    password: str = Field(min_length=12, max_length=256)
    subject_ids: list[int] = Field(default_factory=list)

    @field_validator("email", mode="before")
    @classmethod
    def empty_email_is_none(cls, value):
        return value.strip() or None if isinstance(value, str) else value

    @field_validator("full_name", mode="before")
    @classmethod
    def strip_full_name(cls, value):
        return value.strip() if isinstance(value, str) else value

    @field_validator("subject_ids")
    @classmethod
    def valid_unique_subject_ids(cls, value):
        if any(subject_id <= 0 for subject_id in value) or len(value) != len(set(value)):
            raise ValueError("Subject IDs must be positive and unique.")
        return value


class TeacherUpdate(BaseModel):
    full_name: str | None = Field(default=None, min_length=2, max_length=120)
    email: EmailStr | None = None
    phone: str | None = Field(default=None, max_length=30)
    subject_ids: list[int] | None = None

    @field_validator("full_name", mode="before")
    @classmethod
    def strip_full_name(cls, value):
        return value.strip() if isinstance(value, str) else value

    @field_validator("email", mode="before")
    @classmethod
    def empty_email_is_none(cls, value):
        return value.strip() or None if isinstance(value, str) else value

    @field_validator("subject_ids")
    @classmethod
    def valid_unique_subject_ids(cls, value):
        if value is not None and (any(subject_id <= 0 for subject_id in value) or len(value) != len(set(value))):
            raise ValueError("Subject IDs must be positive and unique.")
        return value

    @model_validator(mode="after")
    def reject_null_name(self):
        if "full_name" in self.model_fields_set and self.full_name is None:
            raise ValueError("full_name cannot be null.")
        if "subject_ids" in self.model_fields_set and self.subject_ids is None:
            raise ValueError("subject_ids cannot be null.")
        return self


class TeacherOut(ORM):
    id: int
    full_name: str
    email: str | None
    phone: str | None
    is_active: bool


class SubjectCreate(InputModel):
    name: str = Field(min_length=1, max_length=100)
    description: str | None = None


class SubjectUpdate(InputModel):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    description: str | None = None

    @model_validator(mode="after")
    def reject_null_name(self):
        if "name" in self.model_fields_set and self.name is None:
            raise ValueError("name cannot be null.")
        return self


class SubjectOut(ORM):
    id: int
    name: str
    description: str | None


class CourseCreate(InputModel):
    title: str = Field(min_length=1, max_length=150)
    course_type: Literal["regular", "special"]
    fee_type: Literal["monthly", "one_time"]
    fee_amount: Decimal = Field(ge=0, max_digits=12, decimal_places=2)
    start_date: date
    end_date: date | None = None
    seat_capacity: int = Field(gt=0)
    teacher_id: int = Field(gt=0)
    subject_id: int = Field(gt=0)

    @model_validator(mode="after")
    def validate_course(self):
        if self.end_date is not None and self.end_date < self.start_date:
            raise ValueError("End date must not precede start date.")
        if (self.course_type, self.fee_type) not in {
            ("regular", "monthly"),
            ("special", "one_time"),
        }:
            raise ValueError("Regular courses require monthly fees; special courses require one-time fees.")
        return self


class CourseUpdate(InputModel):
    title: str | None = Field(default=None, min_length=1, max_length=150)
    course_type: Literal["regular", "special"] | None = None
    fee_type: Literal["monthly", "one_time"] | None = None
    fee_amount: Decimal | None = Field(default=None, ge=0, max_digits=12, decimal_places=2)
    start_date: date | None = None
    end_date: date | None = None
    seat_capacity: int | None = Field(default=None, gt=0)
    teacher_id: int | None = Field(default=None, gt=0)
    subject_id: int | None = Field(default=None, gt=0)

    @model_validator(mode="after")
    def reject_null_required_fields(self):
        for field in ("title", "course_type", "fee_type", "fee_amount", "start_date", "seat_capacity", "teacher_id", "subject_id"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null.")
        return self


class CourseOut(ORM):
    id: int
    title: str
    course_type: str
    fee_type: str
    fee_amount: Decimal
    start_date: date
    end_date: date | None
    seat_capacity: int
    teacher_id: int
    subject_id: int
    is_active: bool


class EnrollmentCreate(InputModel):
    student_id: int = Field(gt=0)
    course_id: int = Field(gt=0)


class EnrollmentOut(ORM):
    id: int
    student_id: int
    course_id: int
    enrolled_at: date
    status: str


class ScheduleCreate(InputModel):
    day_of_week: int = Field(ge=0, le=6)
    start_time: time
    end_time: time
    room: str | None = Field(default=None, max_length=60)

    @model_validator(mode="after")
    def validate_time_range(self):
        if self.end_time <= self.start_time:
            raise ValueError("End time must be after start time.")
        return self


class ScheduleUpdate(InputModel):
    day_of_week: int | None = Field(default=None, ge=0, le=6)
    start_time: time | None = None
    end_time: time | None = None
    room: str | None = Field(default=None, max_length=60)

    @model_validator(mode="after")
    def reject_null_required_fields(self):
        for field in ("day_of_week", "start_time", "end_time"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null.")
        return self


class ExamCreate(InputModel):
    title: str = Field(min_length=1, max_length=150)
    exam_date: date
    total_marks: Decimal = Field(gt=0, max_digits=7, decimal_places=2)


class ExamUpdate(InputModel):
    title: str | None = Field(default=None, min_length=1, max_length=150)
    exam_date: date | None = None
    total_marks: Decimal | None = Field(default=None, gt=0, max_digits=7, decimal_places=2)

    @model_validator(mode="after")
    def reject_null_required_fields(self):
        for field in ("title", "exam_date", "total_marks"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null.")
        return self


class ResultCreate(InputModel):
    student_id: int = Field(gt=0)
    marks_obtained: Decimal = Field(ge=0, max_digits=7, decimal_places=2)
    remarks: str | None = None


class ResultUpdate(InputModel):
    marks_obtained: Decimal = Field(ge=0, max_digits=7, decimal_places=2)
    remarks: str | None = None


class InvoiceCreate(InputModel):
    enrollment_id: int = Field(gt=0)
    period_start: date
    period_end: date | None = None
    due_date: date

    @model_validator(mode="after")
    def validate_period(self):
        if self.period_end is not None and self.period_end < self.period_start:
            raise ValueError("Invoice period end must not precede its start.")
        return self


class PaymentCreate(InputModel):
    amount: Decimal = Field(gt=0, max_digits=12, decimal_places=2)
    payment_method: Literal["cash", "bank", "mobile_banking", "card", "other"]
    reference: str | None = Field(default=None, max_length=120)
    received_by: str | None = Field(default=None, max_length=120)
