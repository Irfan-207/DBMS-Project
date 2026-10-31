INSERT INTO subjects(name,description) VALUES
('Mathematics','Mathematics'),('Physics','Physics'),('Chemistry','Chemistry'),('Programming','Programming')
ON CONFLICT DO NOTHING;
INSERT INTO teachers(full_name,email,phone) VALUES
('Nadia Rahman','nadia@example.com','01710000001'),('Farhan Ahmed','farhan@example.com','01710000002'),
('Samira Islam','samira@example.com','01710000003') ON CONFLICT DO NOTHING;
INSERT INTO teacher_subjects(teacher_id,subject_id)
SELECT t.id,s.id FROM teachers t CROSS JOIN subjects s
WHERE (t.email='nadia@example.com' AND s.name IN ('Mathematics','Physics'))
OR (t.email='farhan@example.com' AND s.name IN ('Programming','Mathematics'))
OR (t.email='samira@example.com' AND s.name IN ('Chemistry','Physics')) ON CONFLICT DO NOTHING;
INSERT INTO students(student_code,full_name,email,phone,guardian_name,guardian_phone,discount_rate) VALUES
('STU-1001','Ayesha Karim','ayesha@example.com','01810000001','M. Karim','01820000001',10),
('STU-1002','Tanvir Hasan','tanvir@example.com','01810000002','S. Hasan','01820000002',0),
('STU-1003','Nusrat Jahan','nusrat@example.com','01810000003','R. Jahan','01820000003',5),
('STU-1004','Rafi Islam','rafi@example.com','01810000004','M. Islam','01820000004',15),
('STU-1005','Sadia Akter','sadia@example.com','01810000005','A. Akter','01820000005',0) ON CONFLICT DO NOTHING;
INSERT INTO courses(title,course_type,fee_type,fee_amount,start_date,seat_capacity,teacher_id,subject_id)
SELECT 'HSC Mathematics Batch A','regular','monthly',2500,CURRENT_DATE-30,30,t.id,s.id FROM teachers t,subjects s
WHERE t.email='nadia@example.com' AND s.name='Mathematics' AND NOT EXISTS(SELECT 1 FROM courses WHERE title='HSC Mathematics Batch A');
INSERT INTO courses(title,course_type,fee_type,fee_amount,start_date,end_date,seat_capacity,teacher_id,subject_id)
SELECT 'Python Bootcamp','special','one_time',6000,CURRENT_DATE,CURRENT_DATE+60,20,t.id,s.id FROM teachers t,subjects s
WHERE t.email='farhan@example.com' AND s.name='Programming' AND NOT EXISTS(SELECT 1 FROM courses WHERE title='Python Bootcamp');
INSERT INTO enrollments(student_id,course_id,status)
SELECT s.id,c.id,'active' FROM students s CROSS JOIN courses c
WHERE (c.title='HSC Mathematics Batch A' AND s.student_code IN ('STU-1001','STU-1002','STU-1003'))
OR (c.title='Python Bootcamp' AND s.student_code IN ('STU-1001','STU-1004')) ON CONFLICT DO NOTHING;
INSERT INTO course_schedules(course_id,day_of_week,start_time,end_time,room)
SELECT id,0,'16:00','17:30','Room 101' FROM courses WHERE title='HSC Mathematics Batch A' ON CONFLICT DO NOTHING;
INSERT INTO course_schedules(course_id,day_of_week,start_time,end_time,room)
SELECT id,2,'18:00','20:00','Lab 1' FROM courses WHERE title='Python Bootcamp' ON CONFLICT DO NOTHING;
INSERT INTO exams(course_id,title,exam_date,total_marks)
SELECT id,'Monthly Test 1',CURRENT_DATE-5,100 FROM courses WHERE title='HSC Mathematics Batch A' ON CONFLICT DO NOTHING;
INSERT INTO results(exam_id,student_id,marks_obtained)
SELECT e.id,s.id,v.marks FROM exams e JOIN courses c ON c.id=e.course_id
JOIN (VALUES('STU-1001',88::numeric),('STU-1002',76::numeric),('STU-1003',93::numeric)) v(code,marks) ON TRUE
JOIN students s ON s.student_code=v.code WHERE e.title='Monthly Test 1' AND c.title='HSC Mathematics Batch A' ON CONFLICT DO NOTHING;

INSERT INTO students(student_code,full_name,email,phone,guardian_name,guardian_phone,discount_rate)
SELECT 'STU-'||g, 'Demo Student '||g, 'student'||g||'@example.com', '018'||LPAD(g::text,8,'0'), 'Guardian '||g, '019'||LPAD(g::text,8,'0'), (g%6)*2
FROM generate_series(1006,1105) g ON CONFLICT DO NOTHING;

UPDATE courses SET seat_capacity=150 WHERE title='HSC Mathematics Batch A';
UPDATE courses SET seat_capacity=150 WHERE title='Python Bootcamp';
INSERT INTO enrollments(student_id,course_id,status)
SELECT s.id,c.id,'active' FROM students s CROSS JOIN courses c
WHERE s.student_code LIKE 'STU-1%' AND c.title='HSC Mathematics Batch A'
ON CONFLICT(student_id,course_id) DO NOTHING;

INSERT INTO invoices(enrollment_id,period_start,period_end,due_date,base_amount,discount_rate,discount_amount,amount_due,status)
SELECT e.id,DATE_TRUNC('month',CURRENT_DATE)::date,(DATE_TRUNC('month',CURRENT_DATE)+INTERVAL '1 month - 1 day')::date,
 CURRENT_DATE+7,c.fee_amount,s.discount_rate,ROUND(c.fee_amount*s.discount_rate/100,2),
 c.fee_amount-ROUND(c.fee_amount*s.discount_rate/100,2),'unpaid'
FROM enrollments e JOIN students s ON s.id=e.student_id JOIN courses c ON c.id=e.course_id
WHERE e.status='active' AND c.fee_type='monthly'
ON CONFLICT(enrollment_id,period_start) DO NOTHING;
