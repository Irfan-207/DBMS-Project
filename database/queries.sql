-- 1. Active enrollment count per course
SELECT c.id, c.title, COUNT(e.id) AS active_students, c.seat_capacity,
       c.seat_capacity-COUNT(e.id) AS seats_remaining
FROM courses c LEFT JOIN enrollments e ON e.course_id=c.id AND e.status='active'
GROUP BY c.id ORDER BY c.title;

-- 2. Outstanding dues per student
SELECT student_id, student_name, COUNT(*) AS open_invoices,
       CAST(SUM(balance) AS NUMERIC(12,2)) AS total_due
FROM v_invoice_balances WHERE balance>0 AND payment_status<>'void'
GROUP BY student_id,student_name ORDER BY total_due DESC;

-- 3. Revenue collected by course
SELECT c.id,c.title,c.course_type,CAST(COALESCE(SUM(p.amount),0) AS NUMERIC(12,2)) AS revenue
FROM courses c LEFT JOIN enrollments e ON e.course_id=c.id
LEFT JOIN invoices i ON i.enrollment_id=e.id AND i.status<>'void'
LEFT JOIN payments p ON p.invoice_id=i.id
GROUP BY c.id ORDER BY revenue DESC;

-- 4. Student exam performance (percentage normalized to total marks)
SELECT s.student_code,s.full_name,
       ROUND(AVG(r.marks_obtained/e.total_marks*100),2) AS average_percentage,
       COUNT(*) AS exams_taken
FROM results r JOIN students s ON s.id=r.student_id JOIN exams e ON e.id=r.exam_id
GROUP BY s.id ORDER BY average_percentage DESC;

-- 5. Top-performing students for each exam
SELECT * FROM (
 SELECT e.id AS exam_id,e.title AS exam_title,s.student_code,s.full_name,
        r.marks_obtained,e.total_marks,
        RANK() OVER(PARTITION BY e.id ORDER BY r.marks_obtained DESC) AS rank_in_exam
 FROM results r JOIN exams e ON e.id=r.exam_id JOIN students s ON s.id=r.student_id
) ranked WHERE rank_in_exam<=3 ORDER BY exam_id,rank_in_exam;

-- 6. Teacher weekly schedules
SELECT t.full_name AS teacher,c.title AS course,s.day_of_week,s.start_time,s.end_time,s.room
FROM course_schedules s JOIN courses c ON c.id=s.course_id JOIN teachers t ON t.id=c.teacher_id
ORDER BY t.full_name,s.day_of_week,s.start_time;

-- 7. Monthly collection trend
SELECT CAST(DATE_TRUNC('month',paid_at) AS DATE) AS month,CAST(SUM(amount) AS NUMERIC(12,2)) AS collected
FROM payments GROUP BY DATE_TRUNC('month',paid_at) ORDER BY month;

-- 8. Dues report example (use the database's execution-plan tooling for a plan view)
SELECT *
FROM v_invoice_balances
WHERE balance > 0
  AND payment_status <> 'void'
ORDER BY due_date;
