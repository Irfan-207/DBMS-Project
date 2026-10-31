CREATE TABLE IF NOT EXISTS students (
 id BIGSERIAL PRIMARY KEY, student_code VARCHAR(30) NOT NULL UNIQUE,
 full_name VARCHAR(120) NOT NULL, email VARCHAR(255) UNIQUE, phone VARCHAR(30),
 guardian_name VARCHAR(120), guardian_phone VARCHAR(30),
 discount_rate NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK(discount_rate BETWEEN 0 AND 100),
 is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS teachers (
 id BIGSERIAL PRIMARY KEY, full_name VARCHAR(120) NOT NULL, email VARCHAR(255) UNIQUE,
 phone VARCHAR(30), is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS user_accounts (
 id BIGSERIAL PRIMARY KEY, email VARCHAR(255) NOT NULL UNIQUE,
 password_hash VARCHAR(255) NOT NULL,
 role VARCHAR(20) NOT NULL CONSTRAINT ck_user_accounts_role CHECK(role IN ('admin','teacher','student')),
 teacher_id BIGINT UNIQUE REFERENCES teachers(id) ON DELETE CASCADE,
 student_id BIGINT CONSTRAINT fk_user_accounts_student REFERENCES students(id) ON DELETE CASCADE,
 is_active BOOLEAN NOT NULL DEFAULT TRUE,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 CONSTRAINT ck_user_accounts_owner CHECK(
  (role='admin' AND teacher_id IS NULL AND student_id IS NULL) OR
  (role='teacher' AND teacher_id IS NOT NULL AND student_id IS NULL) OR
  (role='student' AND teacher_id IS NULL AND student_id IS NOT NULL)
 )
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_user_accounts_student_id
 ON user_accounts(student_id);
CREATE TABLE IF NOT EXISTS auth_sessions (
 id BIGSERIAL PRIMARY KEY,
 user_id BIGINT NOT NULL REFERENCES user_accounts(id) ON DELETE CASCADE,
 token_hash VARCHAR(64) NOT NULL UNIQUE,
 csrf_token VARCHAR(64) NOT NULL,
 expires_at TIMESTAMPTZ NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_auth_sessions_expiry ON auth_sessions(expires_at);
CREATE TABLE IF NOT EXISTS subjects (
 id BIGSERIAL PRIMARY KEY, name VARCHAR(100) NOT NULL UNIQUE, description TEXT
);
CREATE TABLE IF NOT EXISTS teacher_subjects (
 teacher_id BIGINT REFERENCES teachers(id) ON DELETE CASCADE,
 subject_id BIGINT REFERENCES subjects(id) ON DELETE CASCADE,
 PRIMARY KEY(teacher_id, subject_id)
);
CREATE TABLE IF NOT EXISTS courses (
 id BIGSERIAL PRIMARY KEY, title VARCHAR(150) NOT NULL,
 course_type VARCHAR(20) NOT NULL CHECK(course_type IN ('regular','special')),
 fee_type VARCHAR(20) NOT NULL CHECK(fee_type IN ('monthly','one_time')),
 fee_amount NUMERIC(12,2) NOT NULL CHECK(fee_amount >= 0),
 start_date DATE NOT NULL, end_date DATE,
 seat_capacity INTEGER NOT NULL CHECK(seat_capacity > 0),
 teacher_id BIGINT NOT NULL REFERENCES teachers(id) ON DELETE RESTRICT,
 subject_id BIGINT NOT NULL REFERENCES subjects(id) ON DELETE RESTRICT,
 is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 CHECK(end_date IS NULL OR end_date >= start_date),
 CHECK((course_type='regular' AND fee_type='monthly') OR (course_type='special' AND fee_type='one_time'))
);
CREATE TABLE IF NOT EXISTS enrollments (
 id BIGSERIAL PRIMARY KEY, student_id BIGINT NOT NULL REFERENCES students(id) ON DELETE RESTRICT,
 course_id BIGINT NOT NULL REFERENCES courses(id) ON DELETE RESTRICT,
 enrolled_at DATE NOT NULL DEFAULT CURRENT_DATE,
 status VARCHAR(20) NOT NULL DEFAULT 'active' CHECK(status IN ('active','completed','dropped')),
 UNIQUE(student_id,course_id)
);
CREATE TABLE IF NOT EXISTS course_schedules (
 id BIGSERIAL PRIMARY KEY, course_id BIGINT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
 day_of_week SMALLINT NOT NULL CHECK(day_of_week BETWEEN 0 AND 6),
 start_time TIME NOT NULL, end_time TIME NOT NULL, room VARCHAR(60),
 CHECK(end_time > start_time)
);
CREATE TABLE IF NOT EXISTS exams (
 id BIGSERIAL PRIMARY KEY, course_id BIGINT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
 title VARCHAR(150) NOT NULL, exam_date DATE NOT NULL,
 total_marks NUMERIC(7,2) NOT NULL CHECK(total_marks > 0),
 UNIQUE(course_id,title,exam_date)
);
CREATE TABLE IF NOT EXISTS results (
 id BIGSERIAL PRIMARY KEY, exam_id BIGINT NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
 student_id BIGINT NOT NULL REFERENCES students(id) ON DELETE RESTRICT,
 marks_obtained NUMERIC(7,2) NOT NULL CHECK(marks_obtained >= 0), remarks TEXT,
 UNIQUE(exam_id,student_id)
);
CREATE TABLE IF NOT EXISTS invoices (
 id BIGSERIAL PRIMARY KEY, enrollment_id BIGINT NOT NULL REFERENCES enrollments(id) ON DELETE RESTRICT,
 period_start DATE NOT NULL, period_end DATE, due_date DATE NOT NULL,
 base_amount NUMERIC(12,2) NOT NULL CHECK(base_amount >= 0),
 discount_rate NUMERIC(5,2) NOT NULL CHECK(discount_rate BETWEEN 0 AND 100),
 discount_amount NUMERIC(12,2) NOT NULL CHECK(discount_amount >= 0),
 amount_due NUMERIC(12,2) NOT NULL CHECK(amount_due >= 0),
 status VARCHAR(20) NOT NULL DEFAULT 'unpaid' CHECK(status IN ('unpaid','partial','paid','void')),
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 CHECK(discount_amount = ROUND(base_amount * discount_rate / 100, 2)),
 CHECK(amount_due = base_amount - discount_amount),
 CHECK(period_end IS NULL OR period_end >= period_start), UNIQUE(enrollment_id,period_start)
);
CREATE TABLE IF NOT EXISTS payments (
 id BIGSERIAL PRIMARY KEY, invoice_id BIGINT NOT NULL REFERENCES invoices(id) ON DELETE RESTRICT,
 amount NUMERIC(12,2) NOT NULL CHECK(amount > 0),
 payment_method VARCHAR(20) NOT NULL CHECK(payment_method IN ('cash','bank','mobile_banking','card','other')),
 reference VARCHAR(120), paid_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), received_by VARCHAR(120)
);
CREATE INDEX IF NOT EXISTS idx_enrollments_course_status ON enrollments(course_id,status);
CREATE INDEX IF NOT EXISTS idx_enrollments_student ON enrollments(student_id);
CREATE INDEX IF NOT EXISTS idx_invoices_due_status ON invoices(status,due_date);
CREATE INDEX IF NOT EXISTS idx_payments_invoice ON payments(invoice_id);
CREATE INDEX IF NOT EXISTS idx_courses_teacher ON courses(teacher_id);
CREATE INDEX IF NOT EXISTS idx_exams_course_date ON exams(course_id,exam_date);
CREATE OR REPLACE VIEW v_invoice_balances AS
 SELECT i.id AS invoice_id, s.id AS student_id, s.full_name AS student_name, c.title AS course_title,
 i.due_date, i.amount_due, COALESCE(SUM(p.amount),0)::NUMERIC(12,2) AS amount_paid,
 (i.amount_due-COALESCE(SUM(p.amount),0))::NUMERIC(12,2) AS balance,
 CASE WHEN i.status='void' THEN 'void' WHEN COALESCE(SUM(p.amount),0)=0 THEN 'unpaid'
 WHEN COALESCE(SUM(p.amount),0)<i.amount_due THEN 'partial' ELSE 'paid' END AS payment_status
 FROM invoices i JOIN enrollments e ON e.id=i.enrollment_id JOIN students s ON s.id=e.student_id
 JOIN courses c ON c.id=e.course_id LEFT JOIN payments p ON p.invoice_id=i.id
 GROUP BY i.id,s.id,s.full_name,c.title;

CREATE OR REPLACE FUNCTION enforce_enrollment_capacity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cap INTEGER; current_count INTEGER;
BEGIN
 IF NEW.status='active' THEN
  SELECT seat_capacity INTO cap FROM courses WHERE id=NEW.course_id AND is_active=TRUE FOR UPDATE;
  IF cap IS NULL THEN RAISE EXCEPTION 'Course is missing or inactive'; END IF;
  SELECT COUNT(*) INTO current_count FROM enrollments WHERE course_id=NEW.course_id AND status='active' AND (TG_OP='INSERT' OR id<>NEW.id);
  IF current_count>=cap THEN RAISE EXCEPTION 'Course seat capacity exceeded'; END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_enrollment_capacity ON enrollments;
CREATE TRIGGER trg_enrollment_capacity BEFORE INSERT OR UPDATE ON enrollments FOR EACH ROW EXECUTE FUNCTION enforce_enrollment_capacity();

CREATE OR REPLACE FUNCTION enforce_course_capacity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE active_count INTEGER;
BEGIN
 IF NEW.seat_capacity IS DISTINCT FROM OLD.seat_capacity THEN
  SELECT COUNT(*) INTO active_count FROM enrollments WHERE course_id=NEW.id AND status='active';
  IF active_count>NEW.seat_capacity THEN
   RAISE EXCEPTION 'Course capacity cannot be lower than active enrollment count';
  END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_course_capacity ON courses;
CREATE TRIGGER trg_course_capacity BEFORE UPDATE OF seat_capacity ON courses
 FOR EACH ROW EXECUTE FUNCTION enforce_course_capacity();

CREATE OR REPLACE FUNCTION enforce_result_marks() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE max_marks NUMERIC(7,2);
BEGIN
 SELECT total_marks INTO max_marks FROM exams WHERE id=NEW.exam_id FOR UPDATE;
 IF max_marks IS NULL THEN RAISE EXCEPTION 'Exam not found'; END IF;
 IF NEW.marks_obtained<0 OR NEW.marks_obtained>max_marks THEN RAISE EXCEPTION 'Marks must be between zero and total marks'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_result_marks ON results;
CREATE TRIGGER trg_result_marks BEFORE INSERT OR UPDATE ON results FOR EACH ROW EXECUTE FUNCTION enforce_result_marks();

CREATE OR REPLACE FUNCTION enforce_teacher_schedule() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE assigned_teacher BIGINT; conflicting_course BIGINT;
BEGIN
 SELECT teacher_id INTO assigned_teacher FROM courses WHERE id=NEW.course_id FOR UPDATE;
 PERFORM 1 FROM teachers WHERE id=assigned_teacher FOR UPDATE;
 SELECT s.course_id INTO conflicting_course FROM course_schedules s JOIN courses c ON c.id=s.course_id
 WHERE c.teacher_id=assigned_teacher AND s.day_of_week=NEW.day_of_week
 AND s.start_time<NEW.end_time AND s.end_time>NEW.start_time AND s.id<>COALESCE(NEW.id,-1) LIMIT 1;
 IF conflicting_course IS NOT NULL THEN RAISE EXCEPTION 'Teacher has an overlapping schedule'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_teacher_schedule ON course_schedules;
CREATE TRIGGER trg_teacher_schedule BEFORE INSERT OR UPDATE ON course_schedules FOR EACH ROW EXECUTE FUNCTION enforce_teacher_schedule();

CREATE OR REPLACE FUNCTION enforce_course_teacher_schedule() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE conflicting_schedule BIGINT;
BEGIN
 IF NEW.teacher_id IS DISTINCT FROM OLD.teacher_id THEN
  PERFORM 1 FROM teachers WHERE id=NEW.teacher_id FOR UPDATE;
  SELECT existing.id INTO conflicting_schedule
  FROM course_schedules moving
  JOIN course_schedules existing ON existing.day_of_week=moving.day_of_week
   AND existing.start_time<moving.end_time AND existing.end_time>moving.start_time
  JOIN courses assigned_course ON assigned_course.id=existing.course_id
  WHERE moving.course_id=NEW.id AND assigned_course.teacher_id=NEW.teacher_id
   AND assigned_course.id<>NEW.id
  LIMIT 1;
  IF conflicting_schedule IS NOT NULL THEN
   RAISE EXCEPTION 'Teacher has an overlapping schedule';
  END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_course_teacher_schedule ON courses;
CREATE TRIGGER trg_course_teacher_schedule BEFORE UPDATE OF teacher_id ON courses
 FOR EACH ROW EXECUTE FUNCTION enforce_course_teacher_schedule();

CREATE OR REPLACE FUNCTION enforce_exam_marks() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE highest_mark NUMERIC(7,2);
BEGIN
 IF NEW.total_marks IS DISTINCT FROM OLD.total_marks THEN
  SELECT MAX(marks_obtained) INTO highest_mark FROM results WHERE exam_id=NEW.id;
  IF highest_mark IS NOT NULL AND highest_mark>NEW.total_marks THEN
   RAISE EXCEPTION 'Total marks cannot be lower than an existing result';
  END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_exam_marks ON exams;
CREATE TRIGGER trg_exam_marks BEFORE UPDATE OF total_marks ON exams
 FOR EACH ROW EXECUTE FUNCTION enforce_exam_marks();

CREATE OR REPLACE FUNCTION enforce_payment_balance() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE due NUMERIC(12,2); already_paid NUMERIC(12,2);
BEGIN
 SELECT amount_due INTO due FROM invoices WHERE id=NEW.invoice_id AND status<>'void' FOR UPDATE;
 IF due IS NULL THEN RAISE EXCEPTION 'Invoice is missing or void'; END IF;
 SELECT COALESCE(SUM(amount),0) INTO already_paid FROM payments WHERE invoice_id=NEW.invoice_id;
 IF NEW.amount<=0 OR already_paid+NEW.amount>due THEN RAISE EXCEPTION 'Payment exceeds outstanding balance'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_payment_balance ON payments;
CREATE TRIGGER trg_payment_balance BEFORE INSERT ON payments FOR EACH ROW EXECUTE FUNCTION enforce_payment_balance();

CREATE OR REPLACE FUNCTION refresh_invoice_status() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE paid_total NUMERIC(12,2); due_total NUMERIC(12,2);
BEGIN
 SELECT amount_due INTO due_total FROM invoices WHERE id=NEW.invoice_id;
 SELECT COALESCE(SUM(amount),0) INTO paid_total FROM payments WHERE invoice_id=NEW.invoice_id;
 UPDATE invoices SET status=CASE WHEN paid_total=0 THEN 'unpaid' WHEN paid_total<due_total THEN 'partial' ELSE 'paid' END WHERE id=NEW.invoice_id AND status<>'void';
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_refresh_invoice_status ON payments;
CREATE TRIGGER trg_refresh_invoice_status AFTER INSERT ON payments FOR EACH ROW EXECUTE FUNCTION refresh_invoice_status();

CREATE INDEX IF NOT EXISTS idx_students_name ON students(full_name);
CREATE INDEX IF NOT EXISTS idx_courses_subject_type ON courses(subject_id,course_type);
CREATE INDEX IF NOT EXISTS idx_results_exam_marks ON results(exam_id,marks_obtained DESC);
CREATE INDEX IF NOT EXISTS idx_schedules_course_day ON course_schedules(course_id,day_of_week,start_time);
