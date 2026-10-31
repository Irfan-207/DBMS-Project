from decimal import Decimal

from sqlalchemy import *
from sqlalchemy.orm import Mapped, mapped_column
from .database import Base

ID_TYPE = BigInteger().with_variant(Integer, "sqlite")

class Student(Base):
 __tablename__="students"
 __table_args__=(CheckConstraint("discount_rate BETWEEN 0 AND 100"),)
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 student_code:Mapped[str]=mapped_column(String(30),unique=True,nullable=False)
 full_name:Mapped[str]=mapped_column(String(120),nullable=False)
 email:Mapped[str|None]=mapped_column(String(255),unique=True)
 phone:Mapped[str|None]=mapped_column(String(30))
 guardian_name:Mapped[str|None]=mapped_column(String(120))
 guardian_phone:Mapped[str|None]=mapped_column(String(30))
 discount_rate:Mapped[Decimal]=mapped_column(Numeric(5,2),default=0)
 is_active:Mapped[bool]=mapped_column(Boolean,default=True)
 created_at:Mapped[object]=mapped_column(DateTime(timezone=True),server_default=func.now())
class Teacher(Base):
 __tablename__="teachers"
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 full_name:Mapped[str]=mapped_column(String(120),nullable=False)
 email:Mapped[str|None]=mapped_column(String(255),unique=True)
 phone:Mapped[str|None]=mapped_column(String(30))
 is_active:Mapped[bool]=mapped_column(Boolean,default=True)
 created_at:Mapped[object]=mapped_column(DateTime(timezone=True),server_default=func.now())
class UserAccount(Base):
 __tablename__="user_accounts"
 __table_args__=(
  CheckConstraint("role IN ('admin','teacher','student')",name="ck_user_accounts_role"),
  CheckConstraint("(role='admin' AND teacher_id IS NULL AND student_id IS NULL) OR (role='teacher' AND teacher_id IS NOT NULL AND student_id IS NULL) OR (role='student' AND teacher_id IS NULL AND student_id IS NOT NULL)",name="ck_user_accounts_owner"),
   Index("uq_user_accounts_student_id","student_id",unique=True),
 )
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 email:Mapped[str]=mapped_column(String(255),unique=True,nullable=False)
 password_hash:Mapped[str]=mapped_column(String(255),nullable=False)
 role:Mapped[str]=mapped_column(String(20),nullable=False)
 teacher_id:Mapped[int|None]=mapped_column(ForeignKey("teachers.id",ondelete="CASCADE"),unique=True)
 student_id:Mapped[int|None]=mapped_column(ForeignKey("students.id",ondelete="CASCADE",name="fk_user_accounts_student"))
 is_active:Mapped[bool]=mapped_column(Boolean,default=True)
 created_at:Mapped[object]=mapped_column(DateTime(timezone=True),server_default=func.now())
class AuthSession(Base):
 __tablename__="auth_sessions"
 __table_args__=(Index("idx_auth_sessions_expiry","expires_at"),)
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 user_id:Mapped[int]=mapped_column(ForeignKey("user_accounts.id",ondelete="CASCADE"),nullable=False)
 token_hash:Mapped[str]=mapped_column(String(64),unique=True,nullable=False)
 csrf_token:Mapped[str]=mapped_column(String(64),nullable=False)
 expires_at:Mapped[object]=mapped_column(DateTime(timezone=True),nullable=False)
 created_at:Mapped[object]=mapped_column(DateTime(timezone=True),server_default=func.now())
class Subject(Base):
 __tablename__="subjects"
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 name:Mapped[str]=mapped_column(String(100),unique=True,nullable=False)
 description:Mapped[str|None]=mapped_column(Text)
class Course(Base):
 __tablename__="courses"
 __table_args__=(CheckConstraint("course_type IN ('regular','special')"),CheckConstraint("fee_type IN ('monthly','one_time')"),CheckConstraint("fee_amount>=0"),CheckConstraint("seat_capacity>0"),CheckConstraint("end_date IS NULL OR end_date >= start_date"),CheckConstraint("(course_type='regular' AND fee_type='monthly') OR (course_type='special' AND fee_type='one_time')"))
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 title:Mapped[str]=mapped_column(String(150),nullable=False)
 course_type:Mapped[str]=mapped_column(String(20),nullable=False)
 fee_type:Mapped[str]=mapped_column(String(20),nullable=False)
 fee_amount:Mapped[Decimal]=mapped_column(Numeric(12,2),nullable=False)
 start_date:Mapped[object]=mapped_column(Date,nullable=False)
 end_date:Mapped[object|None]=mapped_column(Date)
 seat_capacity:Mapped[int]=mapped_column(Integer,nullable=False)
 teacher_id:Mapped[int]=mapped_column(ForeignKey("teachers.id",ondelete="RESTRICT"),nullable=False)
 subject_id:Mapped[int]=mapped_column(ForeignKey("subjects.id",ondelete="RESTRICT"),nullable=False)
 is_active:Mapped[bool]=mapped_column(Boolean,default=True)
 created_at:Mapped[object]=mapped_column(DateTime(timezone=True),server_default=func.now())
class Enrollment(Base):
 __tablename__="enrollments"
 __table_args__=(UniqueConstraint("student_id","course_id"),CheckConstraint("status IN ('active','completed','dropped')"))
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 student_id:Mapped[int]=mapped_column(ForeignKey("students.id",ondelete="RESTRICT"),nullable=False)
 course_id:Mapped[int]=mapped_column(ForeignKey("courses.id",ondelete="RESTRICT"),nullable=False)
 enrolled_at:Mapped[object]=mapped_column(Date,server_default=func.current_date())
 status:Mapped[str]=mapped_column(String(20),default="active")
class Schedule(Base):
 __tablename__="course_schedules"
 __table_args__=(CheckConstraint("day_of_week BETWEEN 0 AND 6"),CheckConstraint("end_time>start_time"))
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 course_id:Mapped[int]=mapped_column(ForeignKey("courses.id",ondelete="CASCADE"),nullable=False)
 day_of_week:Mapped[int]=mapped_column(SmallInteger,nullable=False)
 start_time:Mapped[object]=mapped_column(Time,nullable=False)
 end_time:Mapped[object]=mapped_column(Time,nullable=False)
 room:Mapped[str|None]=mapped_column(String(60))
class Exam(Base):
 __tablename__="exams"
 __table_args__=(CheckConstraint("total_marks>0"),)
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 course_id:Mapped[int]=mapped_column(ForeignKey("courses.id",ondelete="CASCADE"),nullable=False)
 title:Mapped[str]=mapped_column(String(150),nullable=False)
 exam_date:Mapped[object]=mapped_column(Date,nullable=False)
 total_marks:Mapped[Decimal]=mapped_column(Numeric(7,2),nullable=False)
class Result(Base):
 __tablename__="results"
 __table_args__=(UniqueConstraint("exam_id","student_id"),CheckConstraint("marks_obtained>=0"))
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 exam_id:Mapped[int]=mapped_column(ForeignKey("exams.id",ondelete="CASCADE"),nullable=False)
 student_id:Mapped[int]=mapped_column(ForeignKey("students.id",ondelete="RESTRICT"),nullable=False)
 marks_obtained:Mapped[Decimal]=mapped_column(Numeric(7,2),nullable=False)
 remarks:Mapped[str|None]=mapped_column(Text)
class Invoice(Base):
 __tablename__="invoices"
 __table_args__=(UniqueConstraint("enrollment_id","period_start"),CheckConstraint("base_amount>=0"),CheckConstraint("discount_rate BETWEEN 0 AND 100"),CheckConstraint("discount_amount>=0"),CheckConstraint("amount_due>=0"),CheckConstraint("discount_amount=ROUND(base_amount*discount_rate/100,2)"),CheckConstraint("amount_due=base_amount-discount_amount"),CheckConstraint("period_end IS NULL OR period_end >= period_start"),CheckConstraint("status IN ('unpaid','partial','paid','void')"))
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 enrollment_id:Mapped[int]=mapped_column(ForeignKey("enrollments.id",ondelete="RESTRICT"),nullable=False)
 period_start:Mapped[object]=mapped_column(Date,nullable=False)
 period_end:Mapped[object|None]=mapped_column(Date)
 due_date:Mapped[object]=mapped_column(Date,nullable=False)
 base_amount:Mapped[Decimal]=mapped_column(Numeric(12,2),nullable=False)
 discount_rate:Mapped[Decimal]=mapped_column(Numeric(5,2),nullable=False)
 discount_amount:Mapped[Decimal]=mapped_column(Numeric(12,2),nullable=False)
 amount_due:Mapped[Decimal]=mapped_column(Numeric(12,2),nullable=False)
 status:Mapped[str]=mapped_column(String(20),default="unpaid")
 created_at:Mapped[object]=mapped_column(DateTime(timezone=True),server_default=func.now())
class Payment(Base):
 __tablename__="payments"
 __table_args__=(CheckConstraint("amount>0"),CheckConstraint("payment_method IN ('cash','bank','mobile_banking','card','other')"))
 id:Mapped[int]=mapped_column(ID_TYPE,primary_key=True)
 invoice_id:Mapped[int]=mapped_column(ForeignKey("invoices.id",ondelete="RESTRICT"),nullable=False)
 amount:Mapped[Decimal]=mapped_column(Numeric(12,2),nullable=False)
 payment_method:Mapped[str]=mapped_column(String(20),nullable=False)
 reference:Mapped[str|None]=mapped_column(String(120))
 paid_at:Mapped[object]=mapped_column(DateTime(timezone=True),server_default=func.now())
 received_by:Mapped[str|None]=mapped_column(String(120))

class TeacherSubject(Base):
 __tablename__='teacher_subjects'
 teacher_id:Mapped[int]=mapped_column(ForeignKey('teachers.id',ondelete='CASCADE'),primary_key=True)
 subject_id:Mapped[int]=mapped_column(ForeignKey('subjects.id',ondelete='CASCADE'),primary_key=True)
