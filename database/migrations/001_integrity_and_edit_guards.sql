DO $$
BEGIN
 IF NOT EXISTS (
  SELECT 1 FROM pg_constraint WHERE conname='ck_invoices_discount_amount_matches_rate'
   AND conrelid='invoices'::regclass
 ) THEN
  ALTER TABLE invoices ADD CONSTRAINT ck_invoices_discount_amount_matches_rate
   CHECK(discount_amount=ROUND(base_amount*discount_rate/100,2));
 END IF;
 IF NOT EXISTS (
  SELECT 1 FROM pg_constraint WHERE conname='ck_invoices_amount_due_matches_discount'
   AND conrelid='invoices'::regclass
 ) THEN
  ALTER TABLE invoices ADD CONSTRAINT ck_invoices_amount_due_matches_discount
   CHECK(amount_due=base_amount-discount_amount);
 END IF;
END $$;

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

CREATE OR REPLACE FUNCTION enforce_result_marks() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE max_marks NUMERIC(7,2);
BEGIN
 SELECT total_marks INTO max_marks FROM exams WHERE id=NEW.exam_id FOR UPDATE;
 IF max_marks IS NULL THEN RAISE EXCEPTION 'Exam not found'; END IF;
 IF NEW.marks_obtained<0 OR NEW.marks_obtained>max_marks THEN RAISE EXCEPTION 'Marks must be between zero and total marks'; END IF;
 RETURN NEW;
END $$;
