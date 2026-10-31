# ED-Tech Platform Management System

A database-first coaching-center management application built from the supplied project proposal. It manages student and guardian contacts, teacher subject specialties, regular batches and special courses, enrollments, class schedules, exams/results, invoices/payments, and reporting.

## Technology

- PostgreSQL 16: normalized relational schema, constraints, indexes, reporting view, and integrity triggers
- FastAPI + SQLAlchemy + Pydantic: REST API and validation
- React + TypeScript + Vite: web dashboard and data-entry forms
- Docker Compose: local development environment

## Run locally

1. Install Docker Desktop and start it.
2. In this folder, copy `.env.example` to `.env` only if `.env` does not already exist. Set `ADMIN_EMAIL` and `ADMIN_PASSWORD` to your own email and a unique password of 12-256 characters. The first administrator is provisioned from these values; the project does not ship demo login credentials.
3. Run `docker compose up --build`.
4. Open the frontend at `http://localhost:5173`.
5. Open interactive API documentation at `http://localhost:8000/docs`; health check is `http://localhost:8000/health`.

PostgreSQL initializes `database/init.sql` and then `database/seed.sql` when the database volume is first created. The seed includes 100+ student records and related course/enrollment/invoice examples.

Seeded teachers and students have profiles but no login accounts. Sign in as the administrator and use **Set/reset login** under **Teachers** or **Create/reset login** under **Students** to provision accounts for existing records. Account passwords are securely hashed; there are no shared demo passwords.

**Resetting demo data:** `docker compose down -v` removes the local database volume and all records stored in it. Only run this if you are happy to erase local data. Then run `docker compose up --build` again.

## Main modules

- Students: registration, guardian contacts, per-student discount, profile editing and active/inactive status
- Teachers and subjects: teacher profiles, atomic subject-specialty assignment, account provisioning, profile editing and active/inactive status
- Courses/batches: monthly-fee regular batches and one-time-fee special courses, teacher, subject, dates and capacity; profile editing and status control
- Enrollments: student-course bridge table, status changes, capacity protection and guarded reactivation
- Schedules: day/time slots, overlap detection on creation/edit and teacher reassignment
- Exams/results: exam editing, marks entry and result editing with existing-mark safeguards
- Invoices/payments: invoice generation, discount snapshot, partial payments, payment ledger and balances
- Reports: dues by student, revenue by course, exam performance, top students and dashboard totals
- Access control: admin-managed teacher and student accounts, HttpOnly cookie sessions, CSRF protection, teacher access limited to assigned courses/results, and students limited to their own enrollments/results/billing

## Database safeguards

- `students`, `teachers`, `subjects`, `courses`, `enrollments`, `course_schedules`, `exams`, `results`, `invoices`, `payments`, `teacher_subjects`, `user_accounts`, and `auth_sessions` form the normalized relational model. See `docs/ERD.md`.
- `enrollments` bridges students and courses; `teacher_subjects` bridges teachers and subjects; `results` bridges students and exams.
- Foreign keys, unique constraints, `CHECK` constraints and indexes enforce referential integrity and valid domain values.
- Course-row locks and PostgreSQL triggers prevent active enrollments from exceeding capacity, including concurrent enrollments, reactivation and capacity reductions.
- PostgreSQL teacher-row locks serialize overlapping schedule writes; triggers also guard course teacher reassignment. Exam changes cannot invalidate recorded marks.
- Invoice constraints enforce the rounded discount calculation and `amount_due = base_amount - discount_amount`. Payment row locks and a PostgreSQL trigger prevent concurrent overpayment.
- A payment is recorded as a separate transaction. Invoice discount values are snapshotted at billing time. `v_invoice_balances` derives paid and outstanding amounts from the ledger.
- Teacher creation and subject assignments are one transaction. API enrollment and payment operations use transactions and row-level locks.
- `database/queries.sql` includes the main reporting queries and an `EXPLAIN ANALYZE` example.

The SQL initialization scripts run only when PostgreSQL creates a new, empty data volume. For an existing database, back it up and apply `database/migrations/001_integrity_and_edit_guards.sql` (if not already applied), then `database/migrations/002_student_accounts.sql` before deploying this version. The student-account migration adds a nullable owner link and updates account constraints without deleting or rewriting existing records.

## API overview

| Resource | Endpoints |
|---|---|
| Authentication | `POST /api/auth/login` (administrator, teacher, or student role), `GET /api/auth/me`, `POST /api/auth/logout`, `PUT /api/auth/password` |
| Students | Admin: `GET/POST /api/students`, `PATCH /api/students/{id}`, `PATCH /api/students/{id}/status`, `PUT /api/students/{id}/account`; teacher: `GET /api/teacher/students` (assigned-course roster) |
| Teachers / subjects | `GET/POST /api/teachers`, `PATCH /api/teachers/{id}`, `PATCH /api/teachers/{id}/status`, `PUT /api/teachers/{id}/account`, `GET/POST /api/subjects`, `PATCH /api/subjects/{id}`, `GET /api/teacher-subjects`, `POST/DELETE /api/teachers/{teacher_id}/subjects/{subject_id}` |
| Courses | `GET/POST /api/courses`, `PATCH /api/courses/{id}`, `PATCH /api/courses/{id}/status` |
| Enrollments | `GET/POST /api/enrollments`, `PATCH /api/enrollments/{id}?status=completed` |
| Schedules | `GET /api/schedules`, `POST /api/courses/{id}/schedules`, `PATCH /api/schedules/{id}`, `GET /api/teachers/{id}/schedule` |
| Exams/results | `GET /api/exams`, `POST /api/courses/{id}/exams`, `PATCH /api/exams/{id}`, `GET /api/results`, `POST /api/exams/{id}/results`, `PATCH /api/results/{id}` |
| Billing | `GET/POST /api/invoices`, `GET /api/payments`, `POST /api/invoices/{id}/payments` |
| Reports | `GET /api/reports/summary`, `/outstanding-dues`, `/dues-by-student`, `/course-revenue`, `/exam-performance`, `/top-students` |

For the exact request schemas, response formats, and examples, use Swagger UI at `/docs`.

## Tests and builds

Use Python 3.12. From the project root, install the pinned Python test dependencies and run the unit/API workflow tests:

```powershell
python -m pip install -r requirements-test.txt
python -m pytest -q
```

For the frontend production TypeScript/Vite build, install Node.js 20.19.0 or newer in the 20.x line, or 22.12.0 or newer, then run:

```powershell
Set-Location frontend
npm ci
npm run build
```

## Troubleshooting

- **Compose reports missing `ADMIN_EMAIL` or `ADMIN_PASSWORD`:** set both values in `.env`; use a valid email and a unique password of at least 12 characters.
- **The browser cannot reach the API:** verify `docker compose ps`, check `http://localhost:8000/health`, and confirm `VITE_API_URL` and `CORS_ORIGINS` match the URLs used by the browser.
- **Sign-in succeeds but writes fail with a CSRF error:** reload the page to restore the current session token; non-browser clients must send the latest `csrf_token` as `X-CSRF-Token`.
- **Database tables/triggers appear unchanged after updating SQL:** initialization runs only for an empty volume. Back up existing data and apply the relevant migration script; do not remove a volume to force initialization unless erasing its data is intended.
- **Teacher cannot sign in:** an administrator must create/reset the teacher login, and the teacher profile must be active.
- **Ports 5432, 8000, or 5173 are unavailable:** stop the conflicting service or change the corresponding Compose port mapping and API/CORS URL settings together.

## Important status

This is a local academic/demo implementation, not a production deployment. Authentication uses an eight-hour server-side session stored in PostgreSQL; the browser receives an HttpOnly cookie and must send the returned CSRF token for writes. Admins can manage all records and provision teacher/student accounts linked to existing records. Teachers can view only their assigned courses, schedules, enrollments, exams, and results, and can enter or update results only for students enrolled in their assigned courses. Students can view only their own courses, enrollments, results, invoices, and payments.

Non-browser API clients must retain the session cookie from `/api/auth/login` and send the returned `csrf_token` as the `X-CSRF-Token` header on every write request. Use `/api/auth/me` to restore the current account and CSRF token after a page reload.

The Compose configuration disables the Secure cookie flag for local HTTP development. Set `SESSION_COOKIE_SECURE=true` behind HTTPS before deployment, and configure a trusted `CORS_ORIGINS` value. Do not expose the demo publicly or store real student/payment data until database migrations, automated integration tests, backups, audit logging, and production secret management are in place.
