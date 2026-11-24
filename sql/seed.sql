-- Synthetic data: 200,000 members and 1,500,000 claims over the last 365 days.
-- No real people. Takes about a minute.

INSERT INTO members (member_id, first_name, last_name, dob, plan_code, coverage_start, coverage_end)
SELECT 'MBR-' || lpad(i::text, 6, '0'),
       (ARRAY['Ana','Luis','Maria','Jose','Sofia','Carlos','Elena','Diego','Laura','Miguel','Paula','Jorge'])[1 + i % 12],
       (ARRAY['Garcia','Lopez','Martinez','Hernandez','Perez','Sanchez','Ramirez','Torres','Flores','Rivera'])[1 + (i * 7) % 10],
       DATE '1950-01-01' + (i * 37) % 20000,
       (ARRAY['HMO01','PPO01','EPO01','HDHP1'])[1 + i % 4],
       date_trunc('year', current_date)::date,
       (date_trunc('year', current_date) + interval '1 year - 1 day')::date
FROM generate_series(1, 200000) AS i
ON CONFLICT DO NOTHING;

INSERT INTO claims (member_id, service_date, amount, status)
SELECT 'MBR-' || lpad((1 + floor(random() * 200000))::int::text, 6, '0'),
       current_date - floor(random() * 365)::int,
       round((20 + random() * 1980)::numeric, 2),
       (ARRAY['SUBMITTED','IN_REVIEW','APPROVED','DENIED','PAID'])[1 + floor(random() * 5)::int]
FROM generate_series(1, 1500000);

ANALYZE members;
ANALYZE claims;
