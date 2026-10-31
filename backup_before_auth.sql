--
-- PostgreSQL database dump
--

\restrict vNAnuI0zrI59IsHFkNwaQkgeJqhhGXha1FH6mR0L2sllvUypt9E2y5GrEDCnq0f

-- Dumped from database version 16.15 (Debian 16.15-1.pgdg13+2)
-- Dumped by pg_dump version 16.15 (Debian 16.15-1.pgdg13+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: enforce_course_capacity(); Type: FUNCTION; Schema: public; Owner: edtech
--

CREATE FUNCTION public.enforce_course_capacity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


ALTER FUNCTION public.enforce_course_capacity() OWNER TO edtech;

--
-- Name: enforce_course_teacher_schedule(); Type: FUNCTION; Schema: public; Owner: edtech
--

CREATE FUNCTION public.enforce_course_teacher_schedule() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


ALTER FUNCTION public.enforce_course_teacher_schedule() OWNER TO edtech;

--
-- Name: enforce_enrollment_capacity(); Type: FUNCTION; Schema: public; Owner: edtech
--

CREATE FUNCTION public.enforce_enrollment_capacity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


ALTER FUNCTION public.enforce_enrollment_capacity() OWNER TO edtech;

--
-- Name: enforce_exam_marks(); Type: FUNCTION; Schema: public; Owner: edtech
--

CREATE FUNCTION public.enforce_exam_marks() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


ALTER FUNCTION public.enforce_exam_marks() OWNER TO edtech;

--
-- Name: enforce_payment_balance(); Type: FUNCTION; Schema: public; Owner: edtech
--

CREATE FUNCTION public.enforce_payment_balance() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE due NUMERIC(12,2); already_paid NUMERIC(12,2);
BEGIN
 SELECT amount_due INTO due FROM invoices WHERE id=NEW.invoice_id AND status<>'void' FOR UPDATE;
 IF due IS NULL THEN RAISE EXCEPTION 'Invoice is missing or void'; END IF;
 SELECT COALESCE(SUM(amount),0) INTO already_paid FROM payments WHERE invoice_id=NEW.invoice_id;
 IF NEW.amount<=0 OR already_paid+NEW.amount>due THEN RAISE EXCEPTION 'Payment exceeds outstanding balance'; END IF;
 RETURN NEW;
END $$;


ALTER FUNCTION public.enforce_payment_balance() OWNER TO edtech;

--
-- Name: enforce_result_marks(); Type: FUNCTION; Schema: public; Owner: edtech
--

CREATE FUNCTION public.enforce_result_marks() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE max_marks NUMERIC(7,2);
BEGIN
 SELECT total_marks INTO max_marks FROM exams WHERE id=NEW.exam_id FOR UPDATE;
 IF max_marks IS NULL THEN RAISE EXCEPTION 'Exam not found'; END IF;
 IF NEW.marks_obtained<0 OR NEW.marks_obtained>max_marks THEN RAISE EXCEPTION 'Marks must be between zero and total marks'; END IF;
 RETURN NEW;
END $$;


ALTER FUNCTION public.enforce_result_marks() OWNER TO edtech;

--
-- Name: enforce_teacher_schedule(); Type: FUNCTION; Schema: public; Owner: edtech
--

CREATE FUNCTION public.enforce_teacher_schedule() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


ALTER FUNCTION public.enforce_teacher_schedule() OWNER TO edtech;

--
-- Name: refresh_invoice_status(); Type: FUNCTION; Schema: public; Owner: edtech
--

CREATE FUNCTION public.refresh_invoice_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE paid_total NUMERIC(12,2); due_total NUMERIC(12,2);
BEGIN
 SELECT amount_due INTO due_total FROM invoices WHERE id=NEW.invoice_id;
 SELECT COALESCE(SUM(amount),0) INTO paid_total FROM payments WHERE invoice_id=NEW.invoice_id;
 UPDATE invoices SET status=CASE WHEN paid_total=0 THEN 'unpaid' WHEN paid_total<due_total THEN 'partial' ELSE 'paid' END WHERE id=NEW.invoice_id AND status<>'void';
 RETURN NEW;
END $$;


ALTER FUNCTION public.refresh_invoice_status() OWNER TO edtech;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: auth_sessions; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.auth_sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    token_hash character varying(64) NOT NULL,
    csrf_token character varying(64) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.auth_sessions OWNER TO edtech;

--
-- Name: auth_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.auth_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.auth_sessions_id_seq OWNER TO edtech;

--
-- Name: auth_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.auth_sessions_id_seq OWNED BY public.auth_sessions.id;


--
-- Name: course_schedules; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.course_schedules (
    id bigint NOT NULL,
    course_id bigint NOT NULL,
    day_of_week smallint NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    room character varying(60),
    CONSTRAINT course_schedules_check CHECK ((end_time > start_time)),
    CONSTRAINT course_schedules_day_of_week_check CHECK (((day_of_week >= 0) AND (day_of_week <= 6)))
);


ALTER TABLE public.course_schedules OWNER TO edtech;

--
-- Name: course_schedules_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.course_schedules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.course_schedules_id_seq OWNER TO edtech;

--
-- Name: course_schedules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.course_schedules_id_seq OWNED BY public.course_schedules.id;


--
-- Name: courses; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.courses (
    id bigint NOT NULL,
    title character varying(150) NOT NULL,
    course_type character varying(20) NOT NULL,
    fee_type character varying(20) NOT NULL,
    fee_amount numeric(12,2) NOT NULL,
    start_date date NOT NULL,
    end_date date,
    seat_capacity integer NOT NULL,
    teacher_id bigint NOT NULL,
    subject_id bigint NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT courses_check CHECK (((end_date IS NULL) OR (end_date >= start_date))),
    CONSTRAINT courses_check1 CHECK (((((course_type)::text = 'regular'::text) AND ((fee_type)::text = 'monthly'::text)) OR (((course_type)::text = 'special'::text) AND ((fee_type)::text = 'one_time'::text)))),
    CONSTRAINT courses_course_type_check CHECK (((course_type)::text = ANY ((ARRAY['regular'::character varying, 'special'::character varying])::text[]))),
    CONSTRAINT courses_fee_amount_check CHECK ((fee_amount >= (0)::numeric)),
    CONSTRAINT courses_fee_type_check CHECK (((fee_type)::text = ANY ((ARRAY['monthly'::character varying, 'one_time'::character varying])::text[]))),
    CONSTRAINT courses_seat_capacity_check CHECK ((seat_capacity > 0))
);


ALTER TABLE public.courses OWNER TO edtech;

--
-- Name: courses_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.courses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.courses_id_seq OWNER TO edtech;

--
-- Name: courses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.courses_id_seq OWNED BY public.courses.id;


--
-- Name: enrollments; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.enrollments (
    id bigint NOT NULL,
    student_id bigint NOT NULL,
    course_id bigint NOT NULL,
    enrolled_at date DEFAULT CURRENT_DATE NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    CONSTRAINT enrollments_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'completed'::character varying, 'dropped'::character varying])::text[])))
);


ALTER TABLE public.enrollments OWNER TO edtech;

--
-- Name: enrollments_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.enrollments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.enrollments_id_seq OWNER TO edtech;

--
-- Name: enrollments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.enrollments_id_seq OWNED BY public.enrollments.id;


--
-- Name: exams; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.exams (
    id bigint NOT NULL,
    course_id bigint NOT NULL,
    title character varying(150) NOT NULL,
    exam_date date NOT NULL,
    total_marks numeric(7,2) NOT NULL,
    CONSTRAINT exams_total_marks_check CHECK ((total_marks > (0)::numeric))
);


ALTER TABLE public.exams OWNER TO edtech;

--
-- Name: exams_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.exams_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.exams_id_seq OWNER TO edtech;

--
-- Name: exams_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.exams_id_seq OWNED BY public.exams.id;


--
-- Name: invoices; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.invoices (
    id bigint NOT NULL,
    enrollment_id bigint NOT NULL,
    period_start date NOT NULL,
    period_end date,
    due_date date NOT NULL,
    base_amount numeric(12,2) NOT NULL,
    discount_rate numeric(5,2) NOT NULL,
    discount_amount numeric(12,2) NOT NULL,
    amount_due numeric(12,2) NOT NULL,
    status character varying(20) DEFAULT 'unpaid'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT invoices_amount_due_check CHECK ((amount_due >= (0)::numeric)),
    CONSTRAINT invoices_base_amount_check CHECK ((base_amount >= (0)::numeric)),
    CONSTRAINT invoices_check CHECK ((discount_amount = round(((base_amount * discount_rate) / (100)::numeric), 2))),
    CONSTRAINT invoices_check1 CHECK ((amount_due = (base_amount - discount_amount))),
    CONSTRAINT invoices_check2 CHECK (((period_end IS NULL) OR (period_end >= period_start))),
    CONSTRAINT invoices_discount_amount_check CHECK ((discount_amount >= (0)::numeric)),
    CONSTRAINT invoices_discount_rate_check CHECK (((discount_rate >= (0)::numeric) AND (discount_rate <= (100)::numeric))),
    CONSTRAINT invoices_status_check CHECK (((status)::text = ANY ((ARRAY['unpaid'::character varying, 'partial'::character varying, 'paid'::character varying, 'void'::character varying])::text[])))
);


ALTER TABLE public.invoices OWNER TO edtech;

--
-- Name: invoices_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.invoices_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.invoices_id_seq OWNER TO edtech;

--
-- Name: invoices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.invoices_id_seq OWNED BY public.invoices.id;


--
-- Name: payments; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.payments (
    id bigint NOT NULL,
    invoice_id bigint NOT NULL,
    amount numeric(12,2) NOT NULL,
    payment_method character varying(20) NOT NULL,
    reference character varying(120),
    paid_at timestamp with time zone DEFAULT now() NOT NULL,
    received_by character varying(120),
    CONSTRAINT payments_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT payments_payment_method_check CHECK (((payment_method)::text = ANY ((ARRAY['cash'::character varying, 'bank'::character varying, 'mobile_banking'::character varying, 'card'::character varying, 'other'::character varying])::text[])))
);


ALTER TABLE public.payments OWNER TO edtech;

--
-- Name: payments_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.payments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.payments_id_seq OWNER TO edtech;

--
-- Name: payments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.payments_id_seq OWNED BY public.payments.id;


--
-- Name: results; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.results (
    id bigint NOT NULL,
    exam_id bigint NOT NULL,
    student_id bigint NOT NULL,
    marks_obtained numeric(7,2) NOT NULL,
    remarks text,
    CONSTRAINT results_marks_obtained_check CHECK ((marks_obtained >= (0)::numeric))
);


ALTER TABLE public.results OWNER TO edtech;

--
-- Name: results_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.results_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.results_id_seq OWNER TO edtech;

--
-- Name: results_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.results_id_seq OWNED BY public.results.id;


--
-- Name: students; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.students (
    id bigint NOT NULL,
    student_code character varying(30) NOT NULL,
    full_name character varying(120) NOT NULL,
    email character varying(255),
    phone character varying(30),
    guardian_name character varying(120),
    guardian_phone character varying(30),
    discount_rate numeric(5,2) DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT students_discount_rate_check CHECK (((discount_rate >= (0)::numeric) AND (discount_rate <= (100)::numeric)))
);


ALTER TABLE public.students OWNER TO edtech;

--
-- Name: students_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.students_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.students_id_seq OWNER TO edtech;

--
-- Name: students_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.students_id_seq OWNED BY public.students.id;


--
-- Name: subjects; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.subjects (
    id bigint NOT NULL,
    name character varying(100) NOT NULL,
    description text
);


ALTER TABLE public.subjects OWNER TO edtech;

--
-- Name: subjects_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.subjects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.subjects_id_seq OWNER TO edtech;

--
-- Name: subjects_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.subjects_id_seq OWNED BY public.subjects.id;


--
-- Name: teacher_subjects; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.teacher_subjects (
    teacher_id bigint NOT NULL,
    subject_id bigint NOT NULL
);


ALTER TABLE public.teacher_subjects OWNER TO edtech;

--
-- Name: teachers; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.teachers (
    id bigint NOT NULL,
    full_name character varying(120) NOT NULL,
    email character varying(255),
    phone character varying(30),
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.teachers OWNER TO edtech;

--
-- Name: teachers_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.teachers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.teachers_id_seq OWNER TO edtech;

--
-- Name: teachers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.teachers_id_seq OWNED BY public.teachers.id;


--
-- Name: user_accounts; Type: TABLE; Schema: public; Owner: edtech
--

CREATE TABLE public.user_accounts (
    id bigint NOT NULL,
    email character varying(255) NOT NULL,
    password_hash character varying(255) NOT NULL,
    role character varying(20) NOT NULL,
    teacher_id bigint,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_accounts_check CHECK (((((role)::text = 'admin'::text) AND (teacher_id IS NULL)) OR (((role)::text = 'teacher'::text) AND (teacher_id IS NOT NULL)))),
    CONSTRAINT user_accounts_role_check CHECK (((role)::text = ANY ((ARRAY['admin'::character varying, 'teacher'::character varying])::text[])))
);


ALTER TABLE public.user_accounts OWNER TO edtech;

--
-- Name: user_accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: edtech
--

CREATE SEQUENCE public.user_accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.user_accounts_id_seq OWNER TO edtech;

--
-- Name: user_accounts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: edtech
--

ALTER SEQUENCE public.user_accounts_id_seq OWNED BY public.user_accounts.id;


--
-- Name: v_invoice_balances; Type: VIEW; Schema: public; Owner: edtech
--

CREATE VIEW public.v_invoice_balances AS
SELECT
    NULL::bigint AS invoice_id,
    NULL::bigint AS student_id,
    NULL::character varying(120) AS student_name,
    NULL::character varying(150) AS course_title,
    NULL::date AS due_date,
    NULL::numeric(12,2) AS amount_due,
    NULL::numeric(12,2) AS amount_paid,
    NULL::numeric(12,2) AS balance,
    NULL::text AS payment_status;


ALTER VIEW public.v_invoice_balances OWNER TO edtech;

--
-- Name: auth_sessions id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.auth_sessions ALTER COLUMN id SET DEFAULT nextval('public.auth_sessions_id_seq'::regclass);


--
-- Name: course_schedules id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.course_schedules ALTER COLUMN id SET DEFAULT nextval('public.course_schedules_id_seq'::regclass);


--
-- Name: courses id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.courses ALTER COLUMN id SET DEFAULT nextval('public.courses_id_seq'::regclass);


--
-- Name: enrollments id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.enrollments ALTER COLUMN id SET DEFAULT nextval('public.enrollments_id_seq'::regclass);


--
-- Name: exams id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.exams ALTER COLUMN id SET DEFAULT nextval('public.exams_id_seq'::regclass);


--
-- Name: invoices id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.invoices ALTER COLUMN id SET DEFAULT nextval('public.invoices_id_seq'::regclass);


--
-- Name: payments id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.payments ALTER COLUMN id SET DEFAULT nextval('public.payments_id_seq'::regclass);


--
-- Name: results id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.results ALTER COLUMN id SET DEFAULT nextval('public.results_id_seq'::regclass);


--
-- Name: students id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.students ALTER COLUMN id SET DEFAULT nextval('public.students_id_seq'::regclass);


--
-- Name: subjects id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.subjects ALTER COLUMN id SET DEFAULT nextval('public.subjects_id_seq'::regclass);


--
-- Name: teachers id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.teachers ALTER COLUMN id SET DEFAULT nextval('public.teachers_id_seq'::regclass);


--
-- Name: user_accounts id; Type: DEFAULT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.user_accounts ALTER COLUMN id SET DEFAULT nextval('public.user_accounts_id_seq'::regclass);


--
-- Data for Name: auth_sessions; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.auth_sessions (id, user_id, token_hash, csrf_token, expires_at, created_at) FROM stdin;
1	1	4340ccf120f6c0a097f40b754f598dab4ad74c1d39c56fee745cb1c461f43cdb	z7R71DCzNH6aNccVOwUTD1_IGhIuPR6Waqs0hecnxA4	2026-10-31 16:35:14.396774+00	2026-10-31 08:35:14.34905+00
\.


--
-- Data for Name: course_schedules; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.course_schedules (id, course_id, day_of_week, start_time, end_time, room) FROM stdin;
1	1	0	16:00:00	17:30:00	Room 101
2	2	2	18:00:00	20:00:00	Lab 1
\.


--
-- Data for Name: courses; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.courses (id, title, course_type, fee_type, fee_amount, start_date, end_date, seat_capacity, teacher_id, subject_id, is_active, created_at) FROM stdin;
1	HSC Mathematics Batch A	regular	monthly	2500.00	2026-10-01	\N	150	1	1	t	2026-10-31 08:31:27.584986+00
2	Python Bootcamp	special	one_time	6000.00	2026-10-31	2026-12-30	150	2	4	t	2026-10-31 08:31:27.588481+00
\.


--
-- Data for Name: enrollments; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.enrollments (id, student_id, course_id, enrolled_at, status) FROM stdin;
1	1	1	2026-10-31	active
2	1	2	2026-10-31	active
3	2	1	2026-10-31	active
4	3	1	2026-10-31	active
5	4	2	2026-10-31	active
9	4	1	2026-10-31	active
10	5	1	2026-10-31	active
11	6	1	2026-10-31	active
12	7	1	2026-10-31	active
13	8	1	2026-10-31	active
14	9	1	2026-10-31	active
15	10	1	2026-10-31	active
16	11	1	2026-10-31	active
17	12	1	2026-10-31	active
18	13	1	2026-10-31	active
19	14	1	2026-10-31	active
20	15	1	2026-10-31	active
21	16	1	2026-10-31	active
22	17	1	2026-10-31	active
23	18	1	2026-10-31	active
24	19	1	2026-10-31	active
25	20	1	2026-10-31	active
26	21	1	2026-10-31	active
27	22	1	2026-10-31	active
28	23	1	2026-10-31	active
29	24	1	2026-10-31	active
30	25	1	2026-10-31	active
31	26	1	2026-10-31	active
32	27	1	2026-10-31	active
33	28	1	2026-10-31	active
34	29	1	2026-10-31	active
35	30	1	2026-10-31	active
36	31	1	2026-10-31	active
37	32	1	2026-10-31	active
38	33	1	2026-10-31	active
39	34	1	2026-10-31	active
40	35	1	2026-10-31	active
41	36	1	2026-10-31	active
42	37	1	2026-10-31	active
43	38	1	2026-10-31	active
44	39	1	2026-10-31	active
45	40	1	2026-10-31	active
46	41	1	2026-10-31	active
47	42	1	2026-10-31	active
48	43	1	2026-10-31	active
49	44	1	2026-10-31	active
50	45	1	2026-10-31	active
51	46	1	2026-10-31	active
52	47	1	2026-10-31	active
53	48	1	2026-10-31	active
54	49	1	2026-10-31	active
55	50	1	2026-10-31	active
56	51	1	2026-10-31	active
57	52	1	2026-10-31	active
58	53	1	2026-10-31	active
59	54	1	2026-10-31	active
60	55	1	2026-10-31	active
61	56	1	2026-10-31	active
62	57	1	2026-10-31	active
63	58	1	2026-10-31	active
64	59	1	2026-10-31	active
65	60	1	2026-10-31	active
66	61	1	2026-10-31	active
67	62	1	2026-10-31	active
68	63	1	2026-10-31	active
69	64	1	2026-10-31	active
70	65	1	2026-10-31	active
71	66	1	2026-10-31	active
72	67	1	2026-10-31	active
73	68	1	2026-10-31	active
74	69	1	2026-10-31	active
75	70	1	2026-10-31	active
76	71	1	2026-10-31	active
77	72	1	2026-10-31	active
78	73	1	2026-10-31	active
79	74	1	2026-10-31	active
80	75	1	2026-10-31	active
81	76	1	2026-10-31	active
82	77	1	2026-10-31	active
83	78	1	2026-10-31	active
84	79	1	2026-10-31	active
85	80	1	2026-10-31	active
86	81	1	2026-10-31	active
87	82	1	2026-10-31	active
88	83	1	2026-10-31	active
89	84	1	2026-10-31	active
90	85	1	2026-10-31	active
91	86	1	2026-10-31	active
92	87	1	2026-10-31	active
93	88	1	2026-10-31	active
94	89	1	2026-10-31	active
95	90	1	2026-10-31	active
96	91	1	2026-10-31	active
97	92	1	2026-10-31	active
98	93	1	2026-10-31	active
99	94	1	2026-10-31	active
100	95	1	2026-10-31	active
101	96	1	2026-10-31	active
102	97	1	2026-10-31	active
103	98	1	2026-10-31	active
104	99	1	2026-10-31	active
105	100	1	2026-10-31	active
106	101	1	2026-10-31	active
107	102	1	2026-10-31	active
108	103	1	2026-10-31	active
109	104	1	2026-10-31	active
110	105	1	2026-10-31	active
\.


--
-- Data for Name: exams; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.exams (id, course_id, title, exam_date, total_marks) FROM stdin;
1	1	Monthly Test 1	2026-10-26	100.00
\.


--
-- Data for Name: invoices; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.invoices (id, enrollment_id, period_start, period_end, due_date, base_amount, discount_rate, discount_amount, amount_due, status, created_at) FROM stdin;
1	1	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
2	3	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
3	4	2026-10-01	2026-10-31	2026-11-07	2500.00	5.00	125.00	2375.00	unpaid	2026-10-31 08:31:27.622285+00
4	9	2026-10-01	2026-10-31	2026-11-07	2500.00	15.00	375.00	2125.00	unpaid	2026-10-31 08:31:27.622285+00
5	10	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
6	11	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
7	12	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
8	13	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
9	14	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
10	15	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
11	16	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
12	17	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
13	18	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
14	19	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
15	20	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
16	21	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
17	22	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
18	23	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
19	24	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
20	25	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
21	26	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
22	27	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
23	28	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
24	29	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
25	30	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
26	31	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
27	32	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
28	33	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
29	34	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
30	35	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
31	36	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
32	37	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
33	38	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
34	39	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
35	40	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
36	41	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
37	42	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
38	43	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
39	44	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
40	45	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
41	46	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
42	47	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
43	48	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
44	49	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
45	50	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
46	51	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
47	52	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
48	53	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
49	54	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
50	55	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
51	56	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
52	57	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
53	58	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
54	59	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
55	60	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
56	61	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
57	62	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
58	63	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
59	64	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
60	65	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
61	66	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
62	67	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
63	68	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
64	69	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
65	70	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
66	71	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
67	72	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
68	73	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
69	74	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
70	75	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
71	76	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
72	77	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
73	78	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
74	79	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
75	80	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
76	81	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
77	82	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
78	83	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
79	84	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
80	85	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
81	86	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
82	87	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
83	88	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
84	89	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
85	90	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
86	91	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
87	92	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
88	93	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
89	94	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
90	95	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
91	96	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
92	97	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
93	98	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
94	99	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
95	100	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
96	101	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
97	102	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
98	103	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
99	104	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
100	105	2026-10-01	2026-10-31	2026-11-07	2500.00	4.00	100.00	2400.00	unpaid	2026-10-31 08:31:27.622285+00
101	106	2026-10-01	2026-10-31	2026-11-07	2500.00	6.00	150.00	2350.00	unpaid	2026-10-31 08:31:27.622285+00
102	107	2026-10-01	2026-10-31	2026-11-07	2500.00	8.00	200.00	2300.00	unpaid	2026-10-31 08:31:27.622285+00
103	108	2026-10-01	2026-10-31	2026-11-07	2500.00	10.00	250.00	2250.00	unpaid	2026-10-31 08:31:27.622285+00
104	109	2026-10-01	2026-10-31	2026-11-07	2500.00	0.00	0.00	2500.00	unpaid	2026-10-31 08:31:27.622285+00
105	110	2026-10-01	2026-10-31	2026-11-07	2500.00	2.00	50.00	2450.00	unpaid	2026-10-31 08:31:27.622285+00
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.payments (id, invoice_id, amount, payment_method, reference, paid_at, received_by) FROM stdin;
\.


--
-- Data for Name: results; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.results (id, exam_id, student_id, marks_obtained, remarks) FROM stdin;
1	1	1	88.00	\N
2	1	2	76.00	\N
3	1	3	93.00	\N
\.


--
-- Data for Name: students; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.students (id, student_code, full_name, email, phone, guardian_name, guardian_phone, discount_rate, is_active, created_at) FROM stdin;
1	STU-1001	Ayesha Karim	ayesha@example.com	01810000001	M. Karim	01820000001	10.00	t	2026-10-31 08:31:27.581132+00
2	STU-1002	Tanvir Hasan	tanvir@example.com	01810000002	S. Hasan	01820000002	0.00	t	2026-10-31 08:31:27.581132+00
3	STU-1003	Nusrat Jahan	nusrat@example.com	01810000003	R. Jahan	01820000003	5.00	t	2026-10-31 08:31:27.581132+00
4	STU-1004	Rafi Islam	rafi@example.com	01810000004	M. Islam	01820000004	15.00	t	2026-10-31 08:31:27.581132+00
5	STU-1005	Sadia Akter	sadia@example.com	01810000005	A. Akter	01820000005	0.00	t	2026-10-31 08:31:27.581132+00
6	STU-1006	Demo Student 1006	student1006@example.com	01800001006	Guardian 1006	01900001006	8.00	t	2026-10-31 08:31:27.608315+00
7	STU-1007	Demo Student 1007	student1007@example.com	01800001007	Guardian 1007	01900001007	10.00	t	2026-10-31 08:31:27.608315+00
8	STU-1008	Demo Student 1008	student1008@example.com	01800001008	Guardian 1008	01900001008	0.00	t	2026-10-31 08:31:27.608315+00
9	STU-1009	Demo Student 1009	student1009@example.com	01800001009	Guardian 1009	01900001009	2.00	t	2026-10-31 08:31:27.608315+00
10	STU-1010	Demo Student 1010	student1010@example.com	01800001010	Guardian 1010	01900001010	4.00	t	2026-10-31 08:31:27.608315+00
11	STU-1011	Demo Student 1011	student1011@example.com	01800001011	Guardian 1011	01900001011	6.00	t	2026-10-31 08:31:27.608315+00
12	STU-1012	Demo Student 1012	student1012@example.com	01800001012	Guardian 1012	01900001012	8.00	t	2026-10-31 08:31:27.608315+00
13	STU-1013	Demo Student 1013	student1013@example.com	01800001013	Guardian 1013	01900001013	10.00	t	2026-10-31 08:31:27.608315+00
14	STU-1014	Demo Student 1014	student1014@example.com	01800001014	Guardian 1014	01900001014	0.00	t	2026-10-31 08:31:27.608315+00
15	STU-1015	Demo Student 1015	student1015@example.com	01800001015	Guardian 1015	01900001015	2.00	t	2026-10-31 08:31:27.608315+00
16	STU-1016	Demo Student 1016	student1016@example.com	01800001016	Guardian 1016	01900001016	4.00	t	2026-10-31 08:31:27.608315+00
17	STU-1017	Demo Student 1017	student1017@example.com	01800001017	Guardian 1017	01900001017	6.00	t	2026-10-31 08:31:27.608315+00
18	STU-1018	Demo Student 1018	student1018@example.com	01800001018	Guardian 1018	01900001018	8.00	t	2026-10-31 08:31:27.608315+00
19	STU-1019	Demo Student 1019	student1019@example.com	01800001019	Guardian 1019	01900001019	10.00	t	2026-10-31 08:31:27.608315+00
20	STU-1020	Demo Student 1020	student1020@example.com	01800001020	Guardian 1020	01900001020	0.00	t	2026-10-31 08:31:27.608315+00
21	STU-1021	Demo Student 1021	student1021@example.com	01800001021	Guardian 1021	01900001021	2.00	t	2026-10-31 08:31:27.608315+00
22	STU-1022	Demo Student 1022	student1022@example.com	01800001022	Guardian 1022	01900001022	4.00	t	2026-10-31 08:31:27.608315+00
23	STU-1023	Demo Student 1023	student1023@example.com	01800001023	Guardian 1023	01900001023	6.00	t	2026-10-31 08:31:27.608315+00
24	STU-1024	Demo Student 1024	student1024@example.com	01800001024	Guardian 1024	01900001024	8.00	t	2026-10-31 08:31:27.608315+00
25	STU-1025	Demo Student 1025	student1025@example.com	01800001025	Guardian 1025	01900001025	10.00	t	2026-10-31 08:31:27.608315+00
26	STU-1026	Demo Student 1026	student1026@example.com	01800001026	Guardian 1026	01900001026	0.00	t	2026-10-31 08:31:27.608315+00
27	STU-1027	Demo Student 1027	student1027@example.com	01800001027	Guardian 1027	01900001027	2.00	t	2026-10-31 08:31:27.608315+00
28	STU-1028	Demo Student 1028	student1028@example.com	01800001028	Guardian 1028	01900001028	4.00	t	2026-10-31 08:31:27.608315+00
29	STU-1029	Demo Student 1029	student1029@example.com	01800001029	Guardian 1029	01900001029	6.00	t	2026-10-31 08:31:27.608315+00
30	STU-1030	Demo Student 1030	student1030@example.com	01800001030	Guardian 1030	01900001030	8.00	t	2026-10-31 08:31:27.608315+00
31	STU-1031	Demo Student 1031	student1031@example.com	01800001031	Guardian 1031	01900001031	10.00	t	2026-10-31 08:31:27.608315+00
32	STU-1032	Demo Student 1032	student1032@example.com	01800001032	Guardian 1032	01900001032	0.00	t	2026-10-31 08:31:27.608315+00
33	STU-1033	Demo Student 1033	student1033@example.com	01800001033	Guardian 1033	01900001033	2.00	t	2026-10-31 08:31:27.608315+00
34	STU-1034	Demo Student 1034	student1034@example.com	01800001034	Guardian 1034	01900001034	4.00	t	2026-10-31 08:31:27.608315+00
35	STU-1035	Demo Student 1035	student1035@example.com	01800001035	Guardian 1035	01900001035	6.00	t	2026-10-31 08:31:27.608315+00
36	STU-1036	Demo Student 1036	student1036@example.com	01800001036	Guardian 1036	01900001036	8.00	t	2026-10-31 08:31:27.608315+00
37	STU-1037	Demo Student 1037	student1037@example.com	01800001037	Guardian 1037	01900001037	10.00	t	2026-10-31 08:31:27.608315+00
38	STU-1038	Demo Student 1038	student1038@example.com	01800001038	Guardian 1038	01900001038	0.00	t	2026-10-31 08:31:27.608315+00
39	STU-1039	Demo Student 1039	student1039@example.com	01800001039	Guardian 1039	01900001039	2.00	t	2026-10-31 08:31:27.608315+00
40	STU-1040	Demo Student 1040	student1040@example.com	01800001040	Guardian 1040	01900001040	4.00	t	2026-10-31 08:31:27.608315+00
41	STU-1041	Demo Student 1041	student1041@example.com	01800001041	Guardian 1041	01900001041	6.00	t	2026-10-31 08:31:27.608315+00
42	STU-1042	Demo Student 1042	student1042@example.com	01800001042	Guardian 1042	01900001042	8.00	t	2026-10-31 08:31:27.608315+00
43	STU-1043	Demo Student 1043	student1043@example.com	01800001043	Guardian 1043	01900001043	10.00	t	2026-10-31 08:31:27.608315+00
44	STU-1044	Demo Student 1044	student1044@example.com	01800001044	Guardian 1044	01900001044	0.00	t	2026-10-31 08:31:27.608315+00
45	STU-1045	Demo Student 1045	student1045@example.com	01800001045	Guardian 1045	01900001045	2.00	t	2026-10-31 08:31:27.608315+00
46	STU-1046	Demo Student 1046	student1046@example.com	01800001046	Guardian 1046	01900001046	4.00	t	2026-10-31 08:31:27.608315+00
47	STU-1047	Demo Student 1047	student1047@example.com	01800001047	Guardian 1047	01900001047	6.00	t	2026-10-31 08:31:27.608315+00
48	STU-1048	Demo Student 1048	student1048@example.com	01800001048	Guardian 1048	01900001048	8.00	t	2026-10-31 08:31:27.608315+00
49	STU-1049	Demo Student 1049	student1049@example.com	01800001049	Guardian 1049	01900001049	10.00	t	2026-10-31 08:31:27.608315+00
50	STU-1050	Demo Student 1050	student1050@example.com	01800001050	Guardian 1050	01900001050	0.00	t	2026-10-31 08:31:27.608315+00
51	STU-1051	Demo Student 1051	student1051@example.com	01800001051	Guardian 1051	01900001051	2.00	t	2026-10-31 08:31:27.608315+00
52	STU-1052	Demo Student 1052	student1052@example.com	01800001052	Guardian 1052	01900001052	4.00	t	2026-10-31 08:31:27.608315+00
53	STU-1053	Demo Student 1053	student1053@example.com	01800001053	Guardian 1053	01900001053	6.00	t	2026-10-31 08:31:27.608315+00
54	STU-1054	Demo Student 1054	student1054@example.com	01800001054	Guardian 1054	01900001054	8.00	t	2026-10-31 08:31:27.608315+00
55	STU-1055	Demo Student 1055	student1055@example.com	01800001055	Guardian 1055	01900001055	10.00	t	2026-10-31 08:31:27.608315+00
56	STU-1056	Demo Student 1056	student1056@example.com	01800001056	Guardian 1056	01900001056	0.00	t	2026-10-31 08:31:27.608315+00
57	STU-1057	Demo Student 1057	student1057@example.com	01800001057	Guardian 1057	01900001057	2.00	t	2026-10-31 08:31:27.608315+00
58	STU-1058	Demo Student 1058	student1058@example.com	01800001058	Guardian 1058	01900001058	4.00	t	2026-10-31 08:31:27.608315+00
59	STU-1059	Demo Student 1059	student1059@example.com	01800001059	Guardian 1059	01900001059	6.00	t	2026-10-31 08:31:27.608315+00
60	STU-1060	Demo Student 1060	student1060@example.com	01800001060	Guardian 1060	01900001060	8.00	t	2026-10-31 08:31:27.608315+00
61	STU-1061	Demo Student 1061	student1061@example.com	01800001061	Guardian 1061	01900001061	10.00	t	2026-10-31 08:31:27.608315+00
62	STU-1062	Demo Student 1062	student1062@example.com	01800001062	Guardian 1062	01900001062	0.00	t	2026-10-31 08:31:27.608315+00
63	STU-1063	Demo Student 1063	student1063@example.com	01800001063	Guardian 1063	01900001063	2.00	t	2026-10-31 08:31:27.608315+00
64	STU-1064	Demo Student 1064	student1064@example.com	01800001064	Guardian 1064	01900001064	4.00	t	2026-10-31 08:31:27.608315+00
65	STU-1065	Demo Student 1065	student1065@example.com	01800001065	Guardian 1065	01900001065	6.00	t	2026-10-31 08:31:27.608315+00
66	STU-1066	Demo Student 1066	student1066@example.com	01800001066	Guardian 1066	01900001066	8.00	t	2026-10-31 08:31:27.608315+00
67	STU-1067	Demo Student 1067	student1067@example.com	01800001067	Guardian 1067	01900001067	10.00	t	2026-10-31 08:31:27.608315+00
68	STU-1068	Demo Student 1068	student1068@example.com	01800001068	Guardian 1068	01900001068	0.00	t	2026-10-31 08:31:27.608315+00
69	STU-1069	Demo Student 1069	student1069@example.com	01800001069	Guardian 1069	01900001069	2.00	t	2026-10-31 08:31:27.608315+00
70	STU-1070	Demo Student 1070	student1070@example.com	01800001070	Guardian 1070	01900001070	4.00	t	2026-10-31 08:31:27.608315+00
71	STU-1071	Demo Student 1071	student1071@example.com	01800001071	Guardian 1071	01900001071	6.00	t	2026-10-31 08:31:27.608315+00
72	STU-1072	Demo Student 1072	student1072@example.com	01800001072	Guardian 1072	01900001072	8.00	t	2026-10-31 08:31:27.608315+00
73	STU-1073	Demo Student 1073	student1073@example.com	01800001073	Guardian 1073	01900001073	10.00	t	2026-10-31 08:31:27.608315+00
74	STU-1074	Demo Student 1074	student1074@example.com	01800001074	Guardian 1074	01900001074	0.00	t	2026-10-31 08:31:27.608315+00
75	STU-1075	Demo Student 1075	student1075@example.com	01800001075	Guardian 1075	01900001075	2.00	t	2026-10-31 08:31:27.608315+00
76	STU-1076	Demo Student 1076	student1076@example.com	01800001076	Guardian 1076	01900001076	4.00	t	2026-10-31 08:31:27.608315+00
77	STU-1077	Demo Student 1077	student1077@example.com	01800001077	Guardian 1077	01900001077	6.00	t	2026-10-31 08:31:27.608315+00
78	STU-1078	Demo Student 1078	student1078@example.com	01800001078	Guardian 1078	01900001078	8.00	t	2026-10-31 08:31:27.608315+00
79	STU-1079	Demo Student 1079	student1079@example.com	01800001079	Guardian 1079	01900001079	10.00	t	2026-10-31 08:31:27.608315+00
80	STU-1080	Demo Student 1080	student1080@example.com	01800001080	Guardian 1080	01900001080	0.00	t	2026-10-31 08:31:27.608315+00
81	STU-1081	Demo Student 1081	student1081@example.com	01800001081	Guardian 1081	01900001081	2.00	t	2026-10-31 08:31:27.608315+00
82	STU-1082	Demo Student 1082	student1082@example.com	01800001082	Guardian 1082	01900001082	4.00	t	2026-10-31 08:31:27.608315+00
83	STU-1083	Demo Student 1083	student1083@example.com	01800001083	Guardian 1083	01900001083	6.00	t	2026-10-31 08:31:27.608315+00
84	STU-1084	Demo Student 1084	student1084@example.com	01800001084	Guardian 1084	01900001084	8.00	t	2026-10-31 08:31:27.608315+00
85	STU-1085	Demo Student 1085	student1085@example.com	01800001085	Guardian 1085	01900001085	10.00	t	2026-10-31 08:31:27.608315+00
86	STU-1086	Demo Student 1086	student1086@example.com	01800001086	Guardian 1086	01900001086	0.00	t	2026-10-31 08:31:27.608315+00
87	STU-1087	Demo Student 1087	student1087@example.com	01800001087	Guardian 1087	01900001087	2.00	t	2026-10-31 08:31:27.608315+00
88	STU-1088	Demo Student 1088	student1088@example.com	01800001088	Guardian 1088	01900001088	4.00	t	2026-10-31 08:31:27.608315+00
89	STU-1089	Demo Student 1089	student1089@example.com	01800001089	Guardian 1089	01900001089	6.00	t	2026-10-31 08:31:27.608315+00
90	STU-1090	Demo Student 1090	student1090@example.com	01800001090	Guardian 1090	01900001090	8.00	t	2026-10-31 08:31:27.608315+00
91	STU-1091	Demo Student 1091	student1091@example.com	01800001091	Guardian 1091	01900001091	10.00	t	2026-10-31 08:31:27.608315+00
92	STU-1092	Demo Student 1092	student1092@example.com	01800001092	Guardian 1092	01900001092	0.00	t	2026-10-31 08:31:27.608315+00
93	STU-1093	Demo Student 1093	student1093@example.com	01800001093	Guardian 1093	01900001093	2.00	t	2026-10-31 08:31:27.608315+00
94	STU-1094	Demo Student 1094	student1094@example.com	01800001094	Guardian 1094	01900001094	4.00	t	2026-10-31 08:31:27.608315+00
95	STU-1095	Demo Student 1095	student1095@example.com	01800001095	Guardian 1095	01900001095	6.00	t	2026-10-31 08:31:27.608315+00
96	STU-1096	Demo Student 1096	student1096@example.com	01800001096	Guardian 1096	01900001096	8.00	t	2026-10-31 08:31:27.608315+00
97	STU-1097	Demo Student 1097	student1097@example.com	01800001097	Guardian 1097	01900001097	10.00	t	2026-10-31 08:31:27.608315+00
98	STU-1098	Demo Student 1098	student1098@example.com	01800001098	Guardian 1098	01900001098	0.00	t	2026-10-31 08:31:27.608315+00
99	STU-1099	Demo Student 1099	student1099@example.com	01800001099	Guardian 1099	01900001099	2.00	t	2026-10-31 08:31:27.608315+00
100	STU-1100	Demo Student 1100	student1100@example.com	01800001100	Guardian 1100	01900001100	4.00	t	2026-10-31 08:31:27.608315+00
101	STU-1101	Demo Student 1101	student1101@example.com	01800001101	Guardian 1101	01900001101	6.00	t	2026-10-31 08:31:27.608315+00
102	STU-1102	Demo Student 1102	student1102@example.com	01800001102	Guardian 1102	01900001102	8.00	t	2026-10-31 08:31:27.608315+00
103	STU-1103	Demo Student 1103	student1103@example.com	01800001103	Guardian 1103	01900001103	10.00	t	2026-10-31 08:31:27.608315+00
104	STU-1104	Demo Student 1104	student1104@example.com	01800001104	Guardian 1104	01900001104	0.00	t	2026-10-31 08:31:27.608315+00
105	STU-1105	Demo Student 1105	student1105@example.com	01800001105	Guardian 1105	01900001105	2.00	t	2026-10-31 08:31:27.608315+00
106	MUH2401015M	Irfan Sadik Niloy	irfansadikn@gmail.com	0183832548	01610910094	01760589571	0.05	t	2026-10-31 08:36:42.69033+00
\.


--
-- Data for Name: subjects; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.subjects (id, name, description) FROM stdin;
1	Mathematics	Mathematics
2	Physics	Physics
3	Chemistry	Chemistry
4	Programming	Programming
\.


--
-- Data for Name: teacher_subjects; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.teacher_subjects (teacher_id, subject_id) FROM stdin;
1	1
2	1
1	2
3	2
3	3
2	4
\.


--
-- Data for Name: teachers; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.teachers (id, full_name, email, phone, is_active, created_at) FROM stdin;
1	Nadia Rahman	nadia@example.com	01710000001	t	2026-10-31 08:31:27.574066+00
2	Farhan Ahmed	farhan@example.com	01710000002	t	2026-10-31 08:31:27.574066+00
3	Samira Islam	samira@example.com	01710000003	t	2026-10-31 08:31:27.574066+00
\.


--
-- Data for Name: user_accounts; Type: TABLE DATA; Schema: public; Owner: edtech
--

COPY public.user_accounts (id, email, password_hash, role, teacher_id, is_active, created_at) FROM stdin;
1	admin@example.com	pbkdf2_sha256$390000$dPzUpNgY-Tvgc8fyabybVA$7Zc0EvuRvC4wbF3i8cMd84LMVFaVGN6rwCdvQ_4f2CM	admin	\N	t	2026-10-31 08:33:21.170234+00
\.


--
-- Name: auth_sessions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.auth_sessions_id_seq', 1, true);


--
-- Name: course_schedules_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.course_schedules_id_seq', 2, true);


--
-- Name: courses_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.courses_id_seq', 2, true);


--
-- Name: enrollments_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.enrollments_id_seq', 110, true);


--
-- Name: exams_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.exams_id_seq', 1, true);


--
-- Name: invoices_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.invoices_id_seq', 105, true);


--
-- Name: payments_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.payments_id_seq', 1, false);


--
-- Name: results_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.results_id_seq', 3, true);


--
-- Name: students_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.students_id_seq', 106, true);


--
-- Name: subjects_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.subjects_id_seq', 4, true);


--
-- Name: teachers_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.teachers_id_seq', 3, true);


--
-- Name: user_accounts_id_seq; Type: SEQUENCE SET; Schema: public; Owner: edtech
--

SELECT pg_catalog.setval('public.user_accounts_id_seq', 1, true);


--
-- Name: auth_sessions auth_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_pkey PRIMARY KEY (id);


--
-- Name: auth_sessions auth_sessions_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_token_hash_key UNIQUE (token_hash);


--
-- Name: course_schedules course_schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.course_schedules
    ADD CONSTRAINT course_schedules_pkey PRIMARY KEY (id);


--
-- Name: courses courses_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_pkey PRIMARY KEY (id);


--
-- Name: enrollments enrollments_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_pkey PRIMARY KEY (id);


--
-- Name: enrollments enrollments_student_id_course_id_key; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_student_id_course_id_key UNIQUE (student_id, course_id);


--
-- Name: exams exams_course_id_title_exam_date_key; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.exams
    ADD CONSTRAINT exams_course_id_title_exam_date_key UNIQUE (course_id, title, exam_date);


--
-- Name: exams exams_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.exams
    ADD CONSTRAINT exams_pkey PRIMARY KEY (id);


--
-- Name: invoices invoices_enrollment_id_period_start_key; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_enrollment_id_period_start_key UNIQUE (enrollment_id, period_start);


--
-- Name: invoices invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: results results_exam_id_student_id_key; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.results
    ADD CONSTRAINT results_exam_id_student_id_key UNIQUE (exam_id, student_id);


--
-- Name: results results_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.results
    ADD CONSTRAINT results_pkey PRIMARY KEY (id);


--
-- Name: students students_email_key; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.students
    ADD CONSTRAINT students_email_key UNIQUE (email);


--
-- Name: students students_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.students
    ADD CONSTRAINT students_pkey PRIMARY KEY (id);


--
-- Name: students students_student_code_key; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.students
    ADD CONSTRAINT students_student_code_key UNIQUE (student_code);


--
-- Name: subjects subjects_name_key; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.subjects
    ADD CONSTRAINT subjects_name_key UNIQUE (name);


--
-- Name: subjects subjects_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.subjects
    ADD CONSTRAINT subjects_pkey PRIMARY KEY (id);


--
-- Name: teacher_subjects teacher_subjects_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.teacher_subjects
    ADD CONSTRAINT teacher_subjects_pkey PRIMARY KEY (teacher_id, subject_id);


--
-- Name: teachers teachers_email_key; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.teachers
    ADD CONSTRAINT teachers_email_key UNIQUE (email);


--
-- Name: teachers teachers_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.teachers
    ADD CONSTRAINT teachers_pkey PRIMARY KEY (id);


--
-- Name: user_accounts user_accounts_email_key; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.user_accounts
    ADD CONSTRAINT user_accounts_email_key UNIQUE (email);


--
-- Name: user_accounts user_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.user_accounts
    ADD CONSTRAINT user_accounts_pkey PRIMARY KEY (id);


--
-- Name: user_accounts user_accounts_teacher_id_key; Type: CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.user_accounts
    ADD CONSTRAINT user_accounts_teacher_id_key UNIQUE (teacher_id);


--
-- Name: idx_auth_sessions_expiry; Type: INDEX; Schema: public; Owner: edtech
--

CREATE INDEX idx_auth_sessions_expiry ON public.auth_sessions USING btree (expires_at);


--
-- Name: idx_courses_subject_type; Type: INDEX; Schema: public; Owner: edtech
--

CREATE INDEX idx_courses_subject_type ON public.courses USING btree (subject_id, course_type);


--
-- Name: idx_courses_teacher; Type: INDEX; Schema: public; Owner: edtech
--

CREATE INDEX idx_courses_teacher ON public.courses USING btree (teacher_id);


--
-- Name: idx_enrollments_course_status; Type: INDEX; Schema: public; Owner: edtech
--

CREATE INDEX idx_enrollments_course_status ON public.enrollments USING btree (course_id, status);


--
-- Name: idx_enrollments_student; Type: INDEX; Schema: public; Owner: edtech
--

CREATE INDEX idx_enrollments_student ON public.enrollments USING btree (student_id);


--
-- Name: idx_exams_course_date; Type: INDEX; Schema: public; Owner: edtech
--

CREATE INDEX idx_exams_course_date ON public.exams USING btree (course_id, exam_date);


--
-- Name: idx_invoices_due_status; Type: INDEX; Schema: public; Owner: edtech
--

CREATE INDEX idx_invoices_due_status ON public.invoices USING btree (status, due_date);


--
-- Name: idx_payments_invoice; Type: INDEX; Schema: public; Owner: edtech
--

CREATE INDEX idx_payments_invoice ON public.payments USING btree (invoice_id);


--
-- Name: idx_results_exam_marks; Type: INDEX; Schema: public; Owner: edtech
--

CREATE INDEX idx_results_exam_marks ON public.results USING btree (exam_id, marks_obtained DESC);


--
-- Name: idx_schedules_course_day; Type: INDEX; Schema: public; Owner: edtech
--

CREATE INDEX idx_schedules_course_day ON public.course_schedules USING btree (course_id, day_of_week, start_time);


--
-- Name: idx_students_name; Type: INDEX; Schema: public; Owner: edtech
--

CREATE INDEX idx_students_name ON public.students USING btree (full_name);


--
-- Name: v_invoice_balances _RETURN; Type: RULE; Schema: public; Owner: edtech
--

CREATE OR REPLACE VIEW public.v_invoice_balances AS
 SELECT i.id AS invoice_id,
    s.id AS student_id,
    s.full_name AS student_name,
    c.title AS course_title,
    i.due_date,
    i.amount_due,
    (COALESCE(sum(p.amount), (0)::numeric))::numeric(12,2) AS amount_paid,
    ((i.amount_due - COALESCE(sum(p.amount), (0)::numeric)))::numeric(12,2) AS balance,
        CASE
            WHEN ((i.status)::text = 'void'::text) THEN 'void'::text
            WHEN (COALESCE(sum(p.amount), (0)::numeric) = (0)::numeric) THEN 'unpaid'::text
            WHEN (COALESCE(sum(p.amount), (0)::numeric) < i.amount_due) THEN 'partial'::text
            ELSE 'paid'::text
        END AS payment_status
   FROM ((((public.invoices i
     JOIN public.enrollments e ON ((e.id = i.enrollment_id)))
     JOIN public.students s ON ((s.id = e.student_id)))
     JOIN public.courses c ON ((c.id = e.course_id)))
     LEFT JOIN public.payments p ON ((p.invoice_id = i.id)))
  GROUP BY i.id, s.id, s.full_name, c.title;


--
-- Name: courses trg_course_capacity; Type: TRIGGER; Schema: public; Owner: edtech
--

CREATE TRIGGER trg_course_capacity BEFORE UPDATE OF seat_capacity ON public.courses FOR EACH ROW EXECUTE FUNCTION public.enforce_course_capacity();


--
-- Name: courses trg_course_teacher_schedule; Type: TRIGGER; Schema: public; Owner: edtech
--

CREATE TRIGGER trg_course_teacher_schedule BEFORE UPDATE OF teacher_id ON public.courses FOR EACH ROW EXECUTE FUNCTION public.enforce_course_teacher_schedule();


--
-- Name: enrollments trg_enrollment_capacity; Type: TRIGGER; Schema: public; Owner: edtech
--

CREATE TRIGGER trg_enrollment_capacity BEFORE INSERT OR UPDATE ON public.enrollments FOR EACH ROW EXECUTE FUNCTION public.enforce_enrollment_capacity();


--
-- Name: exams trg_exam_marks; Type: TRIGGER; Schema: public; Owner: edtech
--

CREATE TRIGGER trg_exam_marks BEFORE UPDATE OF total_marks ON public.exams FOR EACH ROW EXECUTE FUNCTION public.enforce_exam_marks();


--
-- Name: payments trg_payment_balance; Type: TRIGGER; Schema: public; Owner: edtech
--

CREATE TRIGGER trg_payment_balance BEFORE INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION public.enforce_payment_balance();


--
-- Name: payments trg_refresh_invoice_status; Type: TRIGGER; Schema: public; Owner: edtech
--

CREATE TRIGGER trg_refresh_invoice_status AFTER INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION public.refresh_invoice_status();


--
-- Name: results trg_result_marks; Type: TRIGGER; Schema: public; Owner: edtech
--

CREATE TRIGGER trg_result_marks BEFORE INSERT OR UPDATE ON public.results FOR EACH ROW EXECUTE FUNCTION public.enforce_result_marks();


--
-- Name: course_schedules trg_teacher_schedule; Type: TRIGGER; Schema: public; Owner: edtech
--

CREATE TRIGGER trg_teacher_schedule BEFORE INSERT OR UPDATE ON public.course_schedules FOR EACH ROW EXECUTE FUNCTION public.enforce_teacher_schedule();


--
-- Name: auth_sessions auth_sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_accounts(id) ON DELETE CASCADE;


--
-- Name: course_schedules course_schedules_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.course_schedules
    ADD CONSTRAINT course_schedules_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: courses courses_subject_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_subject_id_fkey FOREIGN KEY (subject_id) REFERENCES public.subjects(id) ON DELETE RESTRICT;


--
-- Name: courses courses_teacher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_teacher_id_fkey FOREIGN KEY (teacher_id) REFERENCES public.teachers(id) ON DELETE RESTRICT;


--
-- Name: enrollments enrollments_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE RESTRICT;


--
-- Name: enrollments enrollments_student_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE RESTRICT;


--
-- Name: exams exams_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.exams
    ADD CONSTRAINT exams_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: invoices invoices_enrollment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_enrollment_id_fkey FOREIGN KEY (enrollment_id) REFERENCES public.enrollments(id) ON DELETE RESTRICT;


--
-- Name: payments payments_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE RESTRICT;


--
-- Name: results results_exam_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.results
    ADD CONSTRAINT results_exam_id_fkey FOREIGN KEY (exam_id) REFERENCES public.exams(id) ON DELETE CASCADE;


--
-- Name: results results_student_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.results
    ADD CONSTRAINT results_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE RESTRICT;


--
-- Name: teacher_subjects teacher_subjects_subject_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.teacher_subjects
    ADD CONSTRAINT teacher_subjects_subject_id_fkey FOREIGN KEY (subject_id) REFERENCES public.subjects(id) ON DELETE CASCADE;


--
-- Name: teacher_subjects teacher_subjects_teacher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.teacher_subjects
    ADD CONSTRAINT teacher_subjects_teacher_id_fkey FOREIGN KEY (teacher_id) REFERENCES public.teachers(id) ON DELETE CASCADE;


--
-- Name: user_accounts user_accounts_teacher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: edtech
--

ALTER TABLE ONLY public.user_accounts
    ADD CONSTRAINT user_accounts_teacher_id_fkey FOREIGN KEY (teacher_id) REFERENCES public.teachers(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict vNAnuI0zrI59IsHFkNwaQkgeJqhhGXha1FH6mR0L2sllvUypt9E2y5GrEDCnq0f

