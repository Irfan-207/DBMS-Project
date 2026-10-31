# Proposal-to-implementation checklist

| Proposal requirement | Implementation |
|---|---|
| Normalized PostgreSQL schema / ERD | `database/init.sql`, `docs/ERD.md` |
| Student/guardian data and discount | `students`, `/api/students`, Students UI |
| Teachers and subject specialties | `teachers`, `subjects`, `teacher_subjects`, atomic create/update endpoints and teacher form |
| Monthly regular batches / one-time special courses | `courses` fee-type CHECK constraint and API validation |
| Enrollment status and capacity | `enrollments`, row locks, PostgreSQL triggers, status endpoint and reactivation guard |
| Schedule conflict detection | API validation, teacher-row locks, PostgreSQL schedule and teacher-reassignment triggers |
| Exams and results | `exams`, `results`, marks validation, result editing and total-marks safeguard |
| Fee invoices, discounts, partial payments | `invoices`, `payments`, arithmetic CHECK constraints, invoice balance view and payment trigger |
| Reports / SQL aggregation | `/api/reports/*`, `database/queries.sql` |
| 100+ seed records | `database/seed.sql` creates more than 100 student records plus related enrollments and invoices |
| Transaction management | Teacher creation/subject assignment, enrollment changes and payment API operations use transactions and row-level locks |
| Record editing | Frontend edit workflows for students, teachers, subjects, courses, schedules, exams and results; payment rows remain immutable |
| Admin/teacher access roles | `user_accounts`, server-side sessions, CSRF-protected API writes, admin-only management routes, and assigned-course teacher permissions |
| Student/guardian portal | Optional future scope in the proposal; not implemented. |
