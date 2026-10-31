from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime,timedelta,timezone
from decimal import Decimal,ROUND_HALF_UP
import hmac
import os
from fastapi import APIRouter,FastAPI,Depends,HTTPException,Query,Request,Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import EmailStr,TypeAdapter,ValidationError
from sqlalchemy import delete,select,func,text,or_
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from .auth import DUMMY_PASSWORD_HASH,hash_password,hash_session_token,new_csrf_token,new_session_token,verify_password
from .database import Base,engine,get_db,SessionLocal
from . import models as m,schemas as s

SESSION_COOKIE="edtech_session"
SESSION_DURATION=timedelta(hours=8)

@dataclass(frozen=True)
class AuthContext:
 user:m.UserAccount
 session:m.AuthSession

def _teacher_scope(context:AuthContext,column:str)->tuple[str,dict[str,int|None]]:
 if context.user.role=="teacher":
  return f"WHERE {column} = :teacher_id",{"teacher_id":context.user.teacher_id}
 return "",{}

def get_current_user(request:Request)->AuthContext:
 token=request.cookies.get(SESSION_COOKIE)
 if not token: raise HTTPException(401,"Authentication required.")
 with SessionLocal() as db:
  auth_session=db.scalar(select(m.AuthSession).where(m.AuthSession.token_hash==hash_session_token(token)))
  if not auth_session or auth_session.expires_at<=datetime.now(timezone.utc):
   raise HTTPException(401,"Session expired. Sign in again.")
  user=db.get(m.UserAccount,auth_session.user_id)
  if not user or not user.is_active: raise HTTPException(401,"Account is inactive.")
  if user.role=="teacher":
   teacher=db.get(m.Teacher,user.teacher_id)
   if not teacher or not teacher.is_active: raise HTTPException(401,"Teacher account is inactive.")
  elif user.role=="student":
   student=db.get(m.Student,user.student_id)
   if not student or not student.is_active: raise HTTPException(401,"Student account is inactive.")
  return AuthContext(user=user,session=auth_session)

def require_csrf(request:Request,context:AuthContext=Depends(get_current_user)):
 if request.method not in {"GET","HEAD","OPTIONS"}:
  token=request.headers.get("X-CSRF-Token","")
  if not token or not token.isascii() or not hmac.compare_digest(token,context.session.csrf_token):
   raise HTTPException(403,"Invalid CSRF token.")

def require_admin(context:AuthContext=Depends(get_current_user)):
 if context.user.role!="admin": raise HTTPException(403,"Administrator access required.")

def is_secure_cookie()->bool:
 return os.getenv("SESSION_COOKIE_SECURE","true").strip().lower() in {"1","true","yes"}

def set_session_cookie(response:Response,token:str):
 response.set_cookie(SESSION_COOKIE,token,max_age=int(SESSION_DURATION.total_seconds()),httponly=True,secure=is_secure_cookie(),samesite="lax",path="/")

def account_payload(context:AuthContext):
 return {"id":context.user.id,"email":context.user.email,"role":context.user.role,"teacher_id":context.user.teacher_id,"student_id":context.user.student_id,"csrf_token":context.session.csrf_token}

def initialize_admin():
 with SessionLocal.begin() as db:
  if db.scalar(select(m.UserAccount.id).where(m.UserAccount.role=="admin")): return
  email=os.getenv("ADMIN_EMAIL","").strip()
  password=os.getenv("ADMIN_PASSWORD","")
  if not email or len(password)<12 or len(password)>256:
   raise RuntimeError("Set ADMIN_EMAIL and an ADMIN_PASSWORD of 12-256 characters before starting the API.")
  try: normalized_email=str(TypeAdapter(EmailStr).validate_python(email)).lower()
  except ValidationError as error: raise RuntimeError("ADMIN_EMAIL must be a valid email address.") from error
  db.add(m.UserAccount(email=normalized_email,password_hash=hash_password(password),role="admin"))

@asynccontextmanager
async def lifespan(app:FastAPI):
 Base.metadata.create_all(bind=engine)
 with engine.begin() as c:
  c.execute(text("""CREATE OR REPLACE VIEW v_invoice_balances AS
  SELECT i.id invoice_id,s.id student_id,s.full_name student_name,c.title course_title,i.due_date,i.amount_due,
  COALESCE(SUM(p.amount),0)::NUMERIC(12,2) amount_paid,
  (i.amount_due-COALESCE(SUM(p.amount),0))::NUMERIC(12,2) balance,
  CASE WHEN i.status='void' THEN 'void' WHEN COALESCE(SUM(p.amount),0)=0 THEN 'unpaid'
  WHEN COALESCE(SUM(p.amount),0)<i.amount_due THEN 'partial' ELSE 'paid' END payment_status
  FROM invoices i JOIN enrollments e ON e.id=i.enrollment_id JOIN students s ON s.id=e.student_id
  JOIN courses c ON c.id=e.course_id LEFT JOIN payments p ON p.invoice_id=i.id
  GROUP BY i.id,s.id,s.full_name,c.title"""))
 initialize_admin()
 yield
app=FastAPI(title="ED-Tech Platform Management System",version="1.0.0",lifespan=lifespan)
api=APIRouter(dependencies=[Depends(require_csrf)])
app.add_middleware(CORSMiddleware,allow_origins=[origin.strip() for origin in os.getenv("CORS_ORIGINS","http://localhost:5173").split(",") if origin.strip()],allow_credentials=True,allow_methods=["*"],allow_headers=["*"])

@app.post("/api/auth/login")
def login(p:s.LoginRequest,request:Request,response:Response,db:Session=Depends(get_db)):
 origin=request.headers.get("origin")
 allowed_origins={value.strip() for value in os.getenv("CORS_ORIGINS","http://localhost:5173").split(",") if value.strip()}
 if origin and origin not in allowed_origins: raise HTTPException(403,"Untrusted login origin.")
 email=str(p.email).lower()
 user=db.scalar(select(m.UserAccount).where(func.lower(m.UserAccount.email)==email))
 password_is_valid=verify_password(p.password,user.password_hash if user else DUMMY_PASSWORD_HASH)
 if not user or not user.is_active or not password_is_valid or (p.role and p.role!=user.role):
  raise HTTPException(401,"Invalid email or password.")
 token=new_session_token();csrf_token=new_csrf_token()
 now=datetime.now(timezone.utc)
 db.execute(delete(m.AuthSession).where(m.AuthSession.expires_at<=now))
 auth_session=m.AuthSession(user_id=user.id,token_hash=hash_session_token(token),csrf_token=csrf_token,expires_at=now+SESSION_DURATION)
 db.add(auth_session);db.commit();db.refresh(auth_session)
 set_session_cookie(response,token)
 return account_payload(AuthContext(user=user,session=auth_session))

@api.get("/api/auth/me")
def current_account(context:AuthContext=Depends(get_current_user)):
 return account_payload(context)

@api.post("/api/auth/logout")
def logout(response:Response,context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 db.execute(delete(m.AuthSession).where(m.AuthSession.id==context.session.id));db.commit()
 response.delete_cookie(SESSION_COOKIE,path="/",secure=is_secure_cookie(),httponly=True,samesite="lax")
 return {"status":"signed_out"}

@api.put("/api/auth/password")
def change_password(p:s.PasswordChange,response:Response,context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 user=db.scalar(select(m.UserAccount).where(m.UserAccount.id==context.user.id).with_for_update())
 if not user or not verify_password(p.current_password,user.password_hash):
  raise HTTPException(403,"Current password is incorrect.")
 user.password_hash=hash_password(p.new_password)
 db.execute(delete(m.AuthSession).where(m.AuthSession.user_id==user.id))
 token=new_session_token();csrf_token=new_csrf_token()
 auth_session=m.AuthSession(user_id=user.id,token_hash=hash_session_token(token),csrf_token=csrf_token,expires_at=datetime.now(timezone.utc)+SESSION_DURATION)
 db.add(auth_session);db.commit();db.refresh(auth_session)
 set_session_cookie(response,token)
 return account_payload(AuthContext(user=user,session=auth_session))
@app.get("/health")
def health(db:Session=Depends(get_db)): db.execute(text("SELECT 1"));return {"status":"ok","database":"connected"}
@api.get("/api/students",response_model=list[s.StudentOut],dependencies=[Depends(require_admin)])
def students(q:str|None=None,limit:int=Query(100,ge=1,le=500),offset:int=Query(0,ge=0),db:Session=Depends(get_db)):
 st=select(m.Student).order_by(m.Student.id.desc()).limit(limit).offset(offset)
 if q: st=st.where(or_(m.Student.full_name.ilike(f"%{q}%"),m.Student.student_code.ilike(f"%{q}%"),m.Student.email.ilike(f"%{q}%")))
 return db.scalars(st).all()
@api.get("/api/teacher/students")
def teacher_students(context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 if context.user.role!="teacher": raise HTTPException(403,"Teacher access required.")
 return [dict(row) for row in db.execute(select(m.Student.id,m.Student.full_name,m.Student.student_code).join(m.Enrollment,m.Enrollment.student_id==m.Student.id).join(m.Course,m.Course.id==m.Enrollment.course_id).where(m.Course.teacher_id==context.user.teacher_id,m.Enrollment.status!="dropped").distinct().order_by(m.Student.full_name)).mappings().all()]
@api.post("/api/students",response_model=s.StudentOut,status_code=201,dependencies=[Depends(require_admin)])
def add_student(p:s.StudentCreate,db:Session=Depends(get_db)):
 x=m.Student(**p.model_dump());db.add(x)
 try: db.commit();db.refresh(x);return x
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Student code or email already exists.") from e
@api.get("/api/teachers",response_model=list[s.TeacherOut],dependencies=[Depends(require_admin)])
def teachers(db:Session=Depends(get_db)): return db.scalars(select(m.Teacher).order_by(m.Teacher.full_name)).all()
@api.post("/api/teachers",response_model=s.TeacherOut,status_code=201,dependencies=[Depends(require_admin)])
def add_teacher(p:s.TeacherCreate,db:Session=Depends(get_db)):
 try:
  with db.begin():
   if p.subject_ids:
    subject_ids=set(db.scalars(select(m.Subject.id).where(m.Subject.id.in_(p.subject_ids))).all())
    if subject_ids!=set(p.subject_ids): raise HTTPException(422,"One or more subjects do not exist.")
   x=m.Teacher(**p.model_dump(exclude={"password","subject_ids"}));db.add(x);db.flush()
   db.add(m.UserAccount(email=str(p.email).lower(),password_hash=hash_password(p.password),role="teacher",teacher_id=x.id))
   db.add_all(m.TeacherSubject(teacher_id=x.id,subject_id=subject_id) for subject_id in p.subject_ids)
  db.refresh(x);return x
 except HTTPException: raise
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Teacher email may already exist.") from e
@api.patch("/api/teachers/{teacher_id}",response_model=s.TeacherOut,dependencies=[Depends(require_admin)])
def update_teacher(teacher_id:int,p:s.TeacherUpdate,db:Session=Depends(get_db)):
 values=p.model_dump(exclude_unset=True)
 try:
  with db.begin():
   teacher=db.scalar(select(m.Teacher).where(m.Teacher.id==teacher_id).with_for_update())
   if not teacher: raise HTTPException(404,"Teacher not found.")
   account=db.scalar(select(m.UserAccount).where(m.UserAccount.teacher_id==teacher_id))
   if "email" in values and account and values["email"] is None:
    raise HTTPException(422,"A teacher with a login account must retain an email address.")
   if p.subject_ids is not None:
    subject_ids=set(db.scalars(select(m.Subject.id).where(m.Subject.id.in_(p.subject_ids))).all()) if p.subject_ids else set()
    if subject_ids!=set(p.subject_ids): raise HTTPException(422,"One or more subjects do not exist.")
    db.execute(delete(m.TeacherSubject).where(m.TeacherSubject.teacher_id==teacher_id))
    db.add_all(m.TeacherSubject(teacher_id=teacher_id,subject_id=subject_id) for subject_id in p.subject_ids)
   for key,value in values.items():
    if key!="subject_ids": setattr(teacher,key,str(value).lower() if key=="email" and value else value)
   if account and "email" in values: account.email=str(teacher.email).lower()
  db.refresh(teacher);return teacher
 except HTTPException: raise
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Teacher email may already exist.") from e
@api.put("/api/teachers/{teacher_id}/account",dependencies=[Depends(require_admin)])
def set_teacher_account(teacher_id:int,p:s.TeacherAccountCreate,db:Session=Depends(get_db)):
 teacher=db.get(m.Teacher,teacher_id)
 if not teacher: raise HTTPException(404,"Teacher not found.")
 account=db.scalar(select(m.UserAccount).where(m.UserAccount.teacher_id==teacher_id))
 email=str(p.email or (account.email if account else teacher.email or "")).lower()
 if not email: raise HTTPException(422,"Provide a login email or add an email to the teacher profile.")
 if account:
  account.email=email;account.password_hash=hash_password(p.password);account.is_active=teacher.is_active
  db.execute(delete(m.AuthSession).where(m.AuthSession.user_id==account.id))
 else:
  account=m.UserAccount(email=email,password_hash=hash_password(p.password),role="teacher",teacher_id=teacher_id,is_active=teacher.is_active)
  db.add(account)
 try: db.commit()
 except IntegrityError as e: db.rollback();raise HTTPException(409,"An account with this email already exists.") from e
 return {"teacher_id":teacher_id,"email":email,"account_created":True}
@api.get("/api/subjects",response_model=list[s.SubjectOut])
def subjects(db:Session=Depends(get_db)): return db.scalars(select(m.Subject).order_by(m.Subject.name)).all()
@api.post("/api/subjects",response_model=s.SubjectOut,status_code=201,dependencies=[Depends(require_admin)])
def add_subject(p:s.SubjectCreate,db:Session=Depends(get_db)):
 x=m.Subject(**p.model_dump());db.add(x)
 try: db.commit();db.refresh(x);return x
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Subject already exists.") from e
@api.patch("/api/subjects/{subject_id}",response_model=s.SubjectOut,dependencies=[Depends(require_admin)])
def update_subject(subject_id:int,p:s.SubjectUpdate,db:Session=Depends(get_db)):
 x=db.get(m.Subject,subject_id)
 if not x: raise HTTPException(404,"Subject not found.")
 for key,value in p.model_dump(exclude_unset=True).items(): setattr(x,key,value)
 try: db.commit();db.refresh(x);return x
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Subject name already exists.") from e
@api.get("/api/courses",response_model=list[s.CourseOut])
def courses(context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 statement=select(m.Course).order_by(m.Course.id.desc())
 if context.user.role=="teacher": statement=statement.where(m.Course.teacher_id==context.user.teacher_id)
 elif context.user.role=="student":
  enrolled_courses=select(m.Enrollment.course_id).where(m.Enrollment.student_id==context.user.student_id)
  statement=statement.where(m.Course.id.in_(enrolled_courses))
 elif context.user.role!="admin": raise HTTPException(403,"Access denied.")
 return db.scalars(statement).all()
@api.post("/api/courses",response_model=s.CourseOut,status_code=201,dependencies=[Depends(require_admin)])
def add_course(p:s.CourseCreate,db:Session=Depends(get_db)):
 x=m.Course(**p.model_dump());db.add(x)
 try: db.commit();db.refresh(x);return x
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Invalid teacher, subject, or course data.") from e
@api.patch("/api/courses/{course_id}",response_model=s.CourseOut,dependencies=[Depends(require_admin)])
def update_course(course_id:int,p:s.CourseUpdate,db:Session=Depends(get_db)):
 changes=p.model_dump(exclude_unset=True)
 try:
  with db.begin():
   course=db.scalar(select(m.Course).where(m.Course.id==course_id).with_for_update())
   if not course: raise HTTPException(404,"Course not found.")
   existing={field:getattr(course,field) for field in s.CourseCreate.model_fields}
   try: values=s.CourseCreate.model_validate({**existing,**changes}).model_dump()
   except ValidationError as error: raise HTTPException(422,error.errors(include_context=False)) from error
   active_count=db.scalar(select(func.count()).select_from(m.Enrollment).where(m.Enrollment.course_id==course_id,m.Enrollment.status=="active")) or 0
   if values["seat_capacity"]<active_count: raise HTTPException(409,"Capacity cannot be lower than the active enrollment count.")
   for key,value in values.items(): setattr(course,key,value)
  db.refresh(course);return course
 except HTTPException: raise
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Invalid teacher, subject, or course data or teacher schedule conflict.") from e
@api.get("/api/enrollments",response_model=list[s.EnrollmentOut])
def enrollments(context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 statement=select(m.Enrollment).order_by(m.Enrollment.id.desc())
 if context.user.role=="teacher": statement=statement.join(m.Course).where(m.Course.teacher_id==context.user.teacher_id)
 elif context.user.role=="student": statement=statement.where(m.Enrollment.student_id==context.user.student_id)
 elif context.user.role!="admin": raise HTTPException(403,"Access denied.")
 return db.scalars(statement).all()
@api.post("/api/enrollments",response_model=s.EnrollmentOut,status_code=201,dependencies=[Depends(require_admin)])
def add_enrollment(p:s.EnrollmentCreate,db:Session=Depends(get_db)):
 try:
  with db.begin():
   c=db.scalar(select(m.Course).where(m.Course.id==p.course_id).with_for_update())
   if not c or not c.is_active: raise HTTPException(404,"Active course not found.")
   st=db.get(m.Student,p.student_id)
   if not st or not st.is_active: raise HTTPException(404,"Active student not found.")
   if db.scalar(select(m.Enrollment.id).where(m.Enrollment.student_id==p.student_id,m.Enrollment.course_id==p.course_id)): raise HTTPException(409,"Already enrolled.")
   n=db.scalar(select(func.count()).select_from(m.Enrollment).where(m.Enrollment.course_id==c.id,m.Enrollment.status=="active")) or 0
   if n>=c.seat_capacity: raise HTTPException(409,"Course is full.")
   x=m.Enrollment(student_id=p.student_id,course_id=p.course_id,status="active");db.add(x);db.flush();db.refresh(x)
  return x
 except HTTPException: raise
 except IntegrityError as e: raise HTTPException(409,"Enrollment failed.") from e
@api.post("/api/courses/{course_id}/schedules",status_code=201,dependencies=[Depends(require_admin)])
def add_schedule(course_id:int,p:s.ScheduleCreate,db:Session=Depends(get_db)):
 try:
  with db.begin():
   c=db.scalar(select(m.Course).where(m.Course.id==course_id).with_for_update())
   if not c: raise HTTPException(404,"Course not found.")
   db.scalar(select(m.Teacher.id).where(m.Teacher.id==c.teacher_id).with_for_update())
   teacher_courses=select(m.Course.id).where(m.Course.teacher_id==c.teacher_id)
   conflict=db.scalar(select(m.Schedule.id).where(m.Schedule.course_id.in_(teacher_courses),m.Schedule.day_of_week==p.day_of_week,m.Schedule.start_time<p.end_time,m.Schedule.end_time>p.start_time).limit(1))
   if conflict: raise HTTPException(409,"Teacher has an overlapping class.")
   x=m.Schedule(course_id=course_id,**p.model_dump());db.add(x);db.flush()
  db.refresh(x);return x
 except HTTPException: raise
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Schedule could not be saved.") from e
@api.patch("/api/schedules/{schedule_id}",dependencies=[Depends(require_admin)])
def update_schedule(schedule_id:int,p:s.ScheduleUpdate,db:Session=Depends(get_db)):
 changes=p.model_dump(exclude_unset=True)
 try:
  with db.begin():
   schedule=db.scalar(select(m.Schedule).where(m.Schedule.id==schedule_id).with_for_update())
   if not schedule: raise HTTPException(404,"Schedule not found.")
   course=db.scalar(select(m.Course).where(m.Course.id==schedule.course_id).with_for_update())
   if not course: raise HTTPException(404,"Course not found.")
   db.scalar(select(m.Teacher.id).where(m.Teacher.id==course.teacher_id).with_for_update())
   existing={field:getattr(schedule,field) for field in s.ScheduleCreate.model_fields}
   try: values=s.ScheduleCreate.model_validate({**existing,**changes}).model_dump()
   except ValidationError as error: raise HTTPException(422,error.errors(include_context=False)) from error
   teacher_courses=select(m.Course.id).where(m.Course.teacher_id==course.teacher_id)
   conflict=db.scalar(select(m.Schedule.id).where(m.Schedule.id!=schedule_id,m.Schedule.course_id.in_(teacher_courses),m.Schedule.day_of_week==values["day_of_week"],m.Schedule.start_time<values["end_time"],m.Schedule.end_time>values["start_time"]).limit(1))
   if conflict: raise HTTPException(409,"Teacher has an overlapping class.")
   for key,value in values.items(): setattr(schedule,key,value)
  db.refresh(schedule);return schedule
 except HTTPException: raise
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Schedule could not be saved.") from e
@api.post("/api/courses/{course_id}/exams",status_code=201,dependencies=[Depends(require_admin)])
def add_exam(course_id:int,p:s.ExamCreate,db:Session=Depends(get_db)):
 if not db.get(m.Course,course_id): raise HTTPException(404,"Course not found.")
 x=m.Exam(course_id=course_id,**p.model_dump());db.add(x)
 try: db.commit();db.refresh(x);return x
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Exam title already exists for this course and date, or exam data is invalid.") from e
@api.patch("/api/exams/{exam_id}",dependencies=[Depends(require_admin)])
def update_exam(exam_id:int,p:s.ExamUpdate,db:Session=Depends(get_db)):
 changes=p.model_dump(exclude_unset=True)
 try:
  with db.begin():
   exam=db.scalar(select(m.Exam).where(m.Exam.id==exam_id).with_for_update())
   if not exam: raise HTTPException(404,"Exam not found.")
   existing={field:getattr(exam,field) for field in s.ExamCreate.model_fields}
   try: values=s.ExamCreate.model_validate({**existing,**changes}).model_dump()
   except ValidationError as error: raise HTTPException(422,error.errors(include_context=False)) from error
   highest_mark=db.scalar(select(func.max(m.Result.marks_obtained)).where(m.Result.exam_id==exam_id))
   if highest_mark is not None and highest_mark>values["total_marks"]:
    raise HTTPException(409,"Total marks cannot be lower than an existing result.")
   for key,value in values.items(): setattr(exam,key,value)
  db.refresh(exam);return exam
 except HTTPException: raise
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Exam title already exists for this course and date.") from e
@api.post("/api/exams/{exam_id}/results",status_code=201)
def add_result(exam_id:int,p:s.ResultCreate,context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 if context.user.role not in {"admin","teacher"}: raise HTTPException(403,"Staff access required.")
 ex=db.get(m.Exam,exam_id)
 if not ex: raise HTTPException(404,"Exam not found.")
 course=db.get(m.Course,ex.course_id)
 if context.user.role=="teacher" and course.teacher_id!=context.user.teacher_id:
  raise HTTPException(403,"Teachers may only enter results for their assigned courses.")
 if p.marks_obtained>ex.total_marks: raise HTTPException(422,"Marks exceed total marks.")
 if not db.scalar(select(m.Enrollment.id).where(m.Enrollment.course_id==ex.course_id,m.Enrollment.student_id==p.student_id,m.Enrollment.status!="dropped")): raise HTTPException(422,"Student must be enrolled in this course.")
 x=db.scalar(select(m.Result).where(m.Result.exam_id==exam_id,m.Result.student_id==p.student_id))
 if x: x.marks_obtained=p.marks_obtained;x.remarks=p.remarks
 else: x=m.Result(exam_id=exam_id,**p.model_dump());db.add(x)
 try: db.commit();db.refresh(x);return x
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Result already exists or exam data is invalid.") from e
@api.patch("/api/results/{result_id}")
def update_result(result_id:int,p:s.ResultUpdate,context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 if context.user.role not in {"admin","teacher"}: raise HTTPException(403,"Staff access required.")
 result=db.get(m.Result,result_id)
 if not result: raise HTTPException(404,"Result not found.")
 exam=db.get(m.Exam,result.exam_id);course=db.get(m.Course,exam.course_id)
 if context.user.role=="teacher" and course.teacher_id!=context.user.teacher_id:
  raise HTTPException(403,"Teachers may only update results for their assigned courses.")
 if context.user.role=="teacher" and not db.scalar(select(m.Enrollment.id).where(m.Enrollment.course_id==exam.course_id,m.Enrollment.student_id==result.student_id,m.Enrollment.status!="dropped")):
  raise HTTPException(403,"Teachers may only update results for their enrolled students.")
 if p.marks_obtained>exam.total_marks: raise HTTPException(422,"Marks exceed total marks.")
 result.marks_obtained=p.marks_obtained;result.remarks=p.remarks
 try: db.commit();db.refresh(result);return result
 except IntegrityError as e: db.rollback();raise HTTPException(409,"Result could not be updated.") from e
@api.get("/api/invoices")
def invoices(status:str|None=None,context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 st=select(m.Invoice).order_by(m.Invoice.due_date.desc())
 if context.user.role=="student":
  st=st.join(m.Enrollment).where(m.Enrollment.student_id==context.user.student_id)
 elif context.user.role!="admin": raise HTTPException(403,"Administrator or student access required.")
 if status: st=st.where(m.Invoice.status==status)
 return db.scalars(st).all()
@api.post("/api/invoices",status_code=201,dependencies=[Depends(require_admin)])
def add_invoice(p:s.InvoiceCreate,db:Session=Depends(get_db)):
 e=db.get(m.Enrollment,p.enrollment_id)
 if not e or e.status!="active": raise HTTPException(404,"Active enrollment not found.")
 c=db.get(m.Course,e.course_id);student=db.get(m.Student,e.student_id)
 if c.fee_type=="monthly" and p.period_end is None: raise HTTPException(422,"Monthly invoices require period_end.")
 if p.period_end and p.period_end<p.period_start: raise HTTPException(422,"Invalid invoice period.")
 base=Decimal(str(c.fee_amount));rate=Decimal(str(student.discount_rate))
 discount=(base*rate/Decimal("100")).quantize(Decimal("0.01"),rounding=ROUND_HALF_UP)
 x=m.Invoice(enrollment_id=e.id,period_start=p.period_start,period_end=p.period_end,due_date=p.due_date,base_amount=base,discount_rate=rate,discount_amount=discount,amount_due=base-discount,status="unpaid");db.add(x)
 try: db.commit();db.refresh(x);return x
 except IntegrityError as er: db.rollback();raise HTTPException(409,"Invoice already exists for this enrollment and period.") from er
@api.post("/api/invoices/{invoice_id}/payments",status_code=201,dependencies=[Depends(require_admin)])
def add_payment(invoice_id:int,p:s.PaymentCreate,db:Session=Depends(get_db)):
 if p.payment_method not in {"cash","bank","mobile_banking","card","other"}: raise HTTPException(422,"Unsupported payment method.")
 try:
  with db.begin():
   i=db.scalar(select(m.Invoice).where(m.Invoice.id==invoice_id).with_for_update())
   if not i or i.status=="void": raise HTTPException(404,"Active invoice not found.")
   paid=db.scalar(select(func.coalesce(func.sum(m.Payment.amount),0)).where(m.Payment.invoice_id==invoice_id))
   balance=Decimal(str(i.amount_due))-Decimal(str(paid or 0))
   if p.amount>balance: raise HTTPException(422,f"Payment exceeds outstanding balance ({balance}).")
   x=m.Payment(invoice_id=invoice_id,**p.model_dump());db.add(x);db.flush()
   total=Decimal(str(paid or 0))+p.amount;i.status="paid" if total>=Decimal(str(i.amount_due)) else "partial"
  return {"payment_id":x.id,"invoice_id":invoice_id,"amount_paid_total":str(total),"balance":str(balance-p.amount),"status":i.status}
 except HTTPException: raise
 except IntegrityError as e: raise HTTPException(409,"Payment could not be recorded.") from e
@api.get("/api/reports/summary")
def summary(context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 if context.user.role=="student":
  enrollments_count=db.scalar(select(func.count()).select_from(m.Enrollment).where(m.Enrollment.student_id==context.user.student_id)) or 0
  results_count=db.scalar(select(func.count()).select_from(m.Result).where(m.Result.student_id==context.user.student_id)) or 0
  invoice_count=db.scalar(select(func.count()).select_from(m.Invoice).join(m.Enrollment).where(m.Enrollment.student_id==context.user.student_id)) or 0
  payments_total=db.scalar(select(func.coalesce(func.sum(m.Payment.amount),0)).join(m.Invoice).join(m.Enrollment).where(m.Enrollment.student_id==context.user.student_id)) or 0
  return {"enrollments":enrollments_count,"results":results_count,"invoice_count":invoice_count,"payments_total":str(payments_total)}
 if context.user.role=="teacher":
  courses=select(m.Course.id).where(m.Course.teacher_id==context.user.teacher_id)
  return {
   "courses":db.scalar(select(func.count()).select_from(m.Course).where(m.Course.teacher_id==context.user.teacher_id,m.Course.is_active.is_(True))) or 0,
   "active_enrollments":db.scalar(select(func.count()).select_from(m.Enrollment).where(m.Enrollment.course_id.in_(courses),m.Enrollment.status=="active")) or 0,
   "exams":db.scalar(select(func.count()).select_from(m.Exam).where(m.Exam.course_id.in_(courses))) or 0,
  }
 return {"students":db.scalar(select(func.count()).select_from(m.Student).where(m.Student.is_active.is_(True))) or 0,
 "teachers":db.scalar(select(func.count()).select_from(m.Teacher).where(m.Teacher.is_active.is_(True))) or 0,
 "courses":db.scalar(select(func.count()).select_from(m.Course).where(m.Course.is_active.is_(True))) or 0,
 "active_enrollments":db.scalar(select(func.count()).select_from(m.Enrollment).where(m.Enrollment.status=="active")) or 0,
 "collected_revenue":str(db.scalar(select(func.coalesce(func.sum(m.Payment.amount),0))) or 0),
 "invoice_count":db.scalar(select(func.count()).select_from(m.Invoice)) or 0}
@api.get("/api/reports/outstanding-dues",dependencies=[Depends(require_admin)])
def outstanding(db:Session=Depends(get_db)): return [dict(r) for r in db.execute(text("SELECT * FROM v_invoice_balances WHERE balance>0 AND payment_status<>'void' ORDER BY due_date,student_name")).mappings().all()]
@api.get("/api/reports/course-revenue",dependencies=[Depends(require_admin)])
def revenue(db:Session=Depends(get_db)):
 return [dict(r) for r in db.execute(text("""SELECT c.id course_id,c.title,c.course_type,COALESCE(SUM(p.amount),0) collected_revenue FROM courses c LEFT JOIN enrollments e ON e.course_id=c.id LEFT JOIN invoices i ON i.enrollment_id=e.id AND i.status<>'void' LEFT JOIN payments p ON p.invoice_id=i.id GROUP BY c.id ORDER BY collected_revenue DESC""")).mappings().all()]
@api.get("/api/reports/exam-performance")
def performance(context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 if context.user.role not in {"admin","teacher"}: raise HTTPException(403,"Staff access required.")
 scope,params=_teacher_scope(context,"c.teacher_id")
 return [dict(r) for r in db.execute(text(f"""SELECT ex.id exam_id,ex.title exam_title,c.title course_title,COUNT(r.id) students_graded,AVG(r.marks_obtained) average_marks,MAX(r.marks_obtained) highest_marks,ex.total_marks FROM exams ex JOIN courses c ON c.id=ex.course_id LEFT JOIN results r ON r.exam_id=ex.id {scope} GROUP BY ex.id,c.title ORDER BY ex.exam_date DESC"""),params).mappings().all()]

@api.get('/api/schedules')
def list_schedules(context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 if context.user.role not in {"admin","teacher"}: raise HTTPException(403,"Staff access required.")
 scope,params=_teacher_scope(context,"c.teacher_id")
 return [dict(r) for r in db.execute(text(f'''SELECT s.id,s.course_id,c.title course_title,c.teacher_id,t.full_name teacher_name,s.day_of_week,s.start_time,s.end_time,s.room FROM course_schedules s JOIN courses c ON c.id=s.course_id JOIN teachers t ON t.id=c.teacher_id {scope} ORDER BY s.day_of_week,s.start_time'''),params).mappings().all()]
@api.get('/api/exams')
def list_exams(context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 if context.user.role not in {"admin","teacher"}: raise HTTPException(403,"Staff access required.")
 scope,params=_teacher_scope(context,"c.teacher_id")
 return [dict(r) for r in db.execute(text(f'''SELECT e.id,e.course_id,c.title course_title,e.title,e.exam_date,e.total_marks FROM exams e JOIN courses c ON c.id=e.course_id {scope} ORDER BY e.exam_date DESC,e.id DESC'''),params).mappings().all()]
@api.get('/api/results')
def list_results(context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 if context.user.role=="student":
  scope,params="WHERE r.student_id = :student_id",{"student_id":context.user.student_id}
 elif context.user.role in {"admin","teacher"}:
  scope,params=_teacher_scope(context,"c.teacher_id")
 else: raise HTTPException(403,"Access denied.")
 return [dict(r) for r in db.execute(text(f'''SELECT r.id,r.exam_id,e.title exam_title,e.course_id,c.title course_title,r.student_id,s.full_name student_name,s.student_code,r.marks_obtained,e.total_marks,r.remarks FROM results r JOIN exams e ON e.id=r.exam_id JOIN courses c ON c.id=e.course_id JOIN students s ON s.id=r.student_id {scope} ORDER BY e.exam_date DESC,s.full_name'''),params).mappings().all()]
@api.get('/api/payments')
def list_payments(context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 query='''SELECT p.id,p.invoice_id,p.amount,p.payment_method,p.reference,p.paid_at,p.received_by,s.full_name student_name,c.title course_title FROM payments p JOIN invoices i ON i.id=p.invoice_id JOIN enrollments e ON e.id=i.enrollment_id JOIN students s ON s.id=e.student_id JOIN courses c ON c.id=e.course_id'''
 if context.user.role=="student":
  query+=" WHERE e.student_id=:student_id ORDER BY p.paid_at DESC"
  params={"student_id":context.user.student_id}
 elif context.user.role=="admin":
  query+=" ORDER BY p.paid_at DESC"
  params={}
 else: raise HTTPException(403,"Administrator or student access required.")
 return [dict(r) for r in db.execute(text(query),params).mappings().all()]
@api.get('/api/teachers/{teacher_id}/schedule')
def teacher_schedule(teacher_id:int,context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 if context.user.role not in {"admin","teacher"}: raise HTTPException(403,"Staff access required.")
 if not db.get(m.Teacher,teacher_id): raise HTTPException(404,'Teacher not found.')
 if context.user.role=="teacher" and context.user.teacher_id!=teacher_id: raise HTTPException(403,"Teachers may only view their own schedule.")
 return [dict(r) for r in db.execute(text('''SELECT c.title course_title,s.day_of_week,s.start_time,s.end_time,s.room FROM course_schedules s JOIN courses c ON c.id=s.course_id WHERE c.teacher_id=:tid ORDER BY s.day_of_week,s.start_time'''),{'tid':teacher_id}).mappings().all()]
@api.patch('/api/enrollments/{enrollment_id}',dependencies=[Depends(require_admin)])
def change_enrollment(enrollment_id:int,status:str,db:Session=Depends(get_db)):
 if status not in {'active','completed','dropped'}: raise HTTPException(422,'Invalid enrollment status.')
 try:
  with db.begin():
   x=db.scalar(select(m.Enrollment).where(m.Enrollment.id==enrollment_id).with_for_update())
   if not x: raise HTTPException(404,'Enrollment not found.')
   if status=='active':
    c=db.scalar(select(m.Course).where(m.Course.id==x.course_id).with_for_update())
    if not c or not c.is_active: raise HTTPException(409,'Enrollment requires an active course.')
    n=db.scalar(select(func.count()).select_from(m.Enrollment).where(m.Enrollment.course_id==x.course_id,m.Enrollment.status=='active')) or 0
    if x.status!='active' and n>=c.seat_capacity: raise HTTPException(409,'Course is full.')
   x.status=status;db.flush()
  return {'id':x.id,'status':x.status}
 except HTTPException: raise
 except IntegrityError as e: db.rollback();raise HTTPException(409,'Enrollment status could not be updated.') from e
@api.patch('/api/students/{student_id}',dependencies=[Depends(require_admin)])
def update_student(student_id:int,p:s.StudentUpdate,db:Session=Depends(get_db)):
 x=db.get(m.Student,student_id)
 if not x: raise HTTPException(404,'Student not found.')
 for k,v in p.model_dump(exclude_unset=True).items(): setattr(x,k,v)
 try: db.commit();db.refresh(x);return x
 except IntegrityError as e: db.rollback();raise HTTPException(409,'Student code or email already exists.') from e
@api.put('/api/students/{student_id}/account',dependencies=[Depends(require_admin)])
def set_student_account(student_id:int,p:s.StudentAccountCreate,db:Session=Depends(get_db)):
 student=db.get(m.Student,student_id)
 if not student: raise HTTPException(404,'Student not found.')
 account=db.scalar(select(m.UserAccount).where(m.UserAccount.student_id==student_id))
 if account:
  account.email=str(p.email).lower();account.password_hash=hash_password(p.password);account.is_active=student.is_active
  db.execute(delete(m.AuthSession).where(m.AuthSession.user_id==account.id))
 else:
  db.add(m.UserAccount(email=str(p.email).lower(),password_hash=hash_password(p.password),role="student",student_id=student_id,is_active=student.is_active))
 try: db.commit()
 except IntegrityError as e: db.rollback();raise HTTPException(409,'An account with this email already exists, or this student already has an account.') from e
 return {'student_id':student_id,'email':str(p.email).lower(),'account_created':True}
@api.patch('/api/courses/{course_id}/status',dependencies=[Depends(require_admin)])
def change_course_status(course_id:int,is_active:bool,db:Session=Depends(get_db)):
 x=db.get(m.Course,course_id)
 if not x: raise HTTPException(404,'Course not found.')
 x.is_active=is_active;db.commit();return {'id':x.id,'is_active':x.is_active}
@api.patch('/api/students/{student_id}/status',dependencies=[Depends(require_admin)])
def change_student_status(student_id:int,is_active:bool,db:Session=Depends(get_db)):
 x=db.get(m.Student,student_id)
 if not x: raise HTTPException(404,'Student not found.')
 x.is_active=is_active
 account=db.scalar(select(m.UserAccount).where(m.UserAccount.student_id==student_id))
 if account:
  account.is_active=is_active
  if not is_active: db.execute(delete(m.AuthSession).where(m.AuthSession.user_id==account.id))
 db.commit();return {'id':x.id,'is_active':x.is_active}
@api.patch('/api/teachers/{teacher_id}/status',dependencies=[Depends(require_admin)])
def change_teacher_status(teacher_id:int,is_active:bool,db:Session=Depends(get_db)):
 teacher=db.get(m.Teacher,teacher_id)
 if not teacher: raise HTTPException(404,'Teacher not found.')
 teacher.is_active=is_active
 account=db.scalar(select(m.UserAccount).where(m.UserAccount.teacher_id==teacher_id))
 if account:
  account.is_active=is_active
  if not is_active: db.execute(delete(m.AuthSession).where(m.AuthSession.user_id==account.id))
 db.commit()
 return {'id':teacher.id,'is_active':teacher.is_active}
@api.get('/api/reports/top-students')
def top_students(limit:int=Query(10,ge=1,le=100),context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 if context.user.role not in {"admin","teacher"}: raise HTTPException(403,"Staff access required.")
 scope,params=_teacher_scope(context,"c.teacher_id")
 params["lim"]=limit
 return [dict(r) for r in db.execute(text(f'''SELECT s.id student_id,s.full_name,s.student_code,ROUND(AVG(r.marks_obtained/NULLIF(e.total_marks,0)*100),2) average_percentage,COUNT(r.id) exams_taken FROM students s JOIN results r ON r.student_id=s.id JOIN exams e ON e.id=r.exam_id JOIN courses c ON c.id=e.course_id {scope} GROUP BY s.id ORDER BY average_percentage DESC LIMIT :lim'''),params).mappings().all()]
@api.get('/api/reports/dues-by-student',dependencies=[Depends(require_admin)])
def dues_by_student(db:Session=Depends(get_db)):
 return [dict(r) for r in db.execute(text('''SELECT student_id,student_name,COUNT(*) open_invoices,SUM(balance)::numeric(12,2) total_due FROM v_invoice_balances WHERE balance>0 AND payment_status<>'void' GROUP BY student_id,student_name ORDER BY total_due DESC''')).mappings().all()]

@api.get('/api/teacher-subjects')
def list_teacher_subjects(context:AuthContext=Depends(get_current_user),db:Session=Depends(get_db)):
 if context.user.role not in {"admin","teacher"}: raise HTTPException(403,"Staff access required.")
 scope,params=_teacher_scope(context,"ts.teacher_id")
 return [dict(r) for r in db.execute(text(f'''SELECT ts.teacher_id,t.full_name teacher_name,ts.subject_id,s.name subject_name FROM teacher_subjects ts JOIN teachers t ON t.id=ts.teacher_id JOIN subjects s ON s.id=ts.subject_id {scope} ORDER BY t.full_name,s.name'''),params).mappings().all()]
@api.post('/api/teachers/{teacher_id}/subjects/{subject_id}',status_code=201,dependencies=[Depends(require_admin)])
def assign_teacher_subject(teacher_id:int,subject_id:int,db:Session=Depends(get_db)):
 if not db.get(m.Teacher,teacher_id): raise HTTPException(404,'Teacher not found.')
 if not db.get(m.Subject,subject_id): raise HTTPException(404,'Subject not found.')
 try:
  db.execute(text('INSERT INTO teacher_subjects(teacher_id,subject_id) VALUES (:t,:s) ON CONFLICT DO NOTHING'),{'t':teacher_id,'s':subject_id});db.commit()
 except IntegrityError as e: db.rollback();raise HTTPException(409,'Could not assign subject.') from e
 return {'teacher_id':teacher_id,'subject_id':subject_id,'assigned':True}
@api.delete('/api/teachers/{teacher_id}/subjects/{subject_id}',dependencies=[Depends(require_admin)])
def remove_teacher_subject(teacher_id:int,subject_id:int,db:Session=Depends(get_db)):
 result=db.execute(text('DELETE FROM teacher_subjects WHERE teacher_id=:t AND subject_id=:s'),{'t':teacher_id,'s':subject_id});db.commit()
 if not result.rowcount: raise HTTPException(404,'Teacher-subject assignment not found.')
 return {'teacher_id':teacher_id,'subject_id':subject_id,'assigned':False}

app.include_router(api)
