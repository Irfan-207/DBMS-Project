BEGIN;

ALTER TABLE user_accounts
 ADD COLUMN IF NOT EXISTS student_id BIGINT;

DO $$
BEGIN
 IF NOT EXISTS (
  SELECT 1 FROM pg_constraint
  WHERE conname='fk_user_accounts_student'
   AND conrelid='user_accounts'::regclass
 ) THEN
  ALTER TABLE user_accounts ADD CONSTRAINT fk_user_accounts_student
   FOREIGN KEY(student_id) REFERENCES students(id) ON DELETE CASCADE;
 END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_accounts_student_id
 ON user_accounts(student_id);

ALTER TABLE user_accounts
 DROP CONSTRAINT IF EXISTS user_accounts_role_check,
 DROP CONSTRAINT IF EXISTS user_accounts_check,
 DROP CONSTRAINT IF EXISTS ck_user_accounts_role,
 DROP CONSTRAINT IF EXISTS ck_user_accounts_owner;

ALTER TABLE user_accounts
 ADD CONSTRAINT ck_user_accounts_role
  CHECK(role IN ('admin','teacher','student')),
 ADD CONSTRAINT ck_user_accounts_owner
  CHECK(
   (role='admin' AND teacher_id IS NULL AND student_id IS NULL) OR
   (role='teacher' AND teacher_id IS NOT NULL AND student_id IS NULL) OR
   (role='student' AND teacher_id IS NULL AND student_id IS NOT NULL)
  );

COMMIT;
