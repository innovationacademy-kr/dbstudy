/*
** 간단하게 데이터 테이블 생성, 수정, 조회, 삭제와 열의 옵션에 대해 알아본다.
*/

SHOW TABLES; -- 현재 생성되어 있는 테이블을 보여준다.

CREATE TABLE ftseoul(
  id INT,
  first_name VARCHAR(128),
  last_name VARCHAR(128)
);

SHOW TABLES; -- ftseoul 테이블 생성 확인

INSERT INTO ftseoul(id, first_name, last_name)
VALUES (1, 'Jonghyun', 'Lim');

SELECT * FROM ftseoul; -- ftseoul 테이블의 내용 확인

INSERT INTO ftseoul(id, first_name, last_name) -- 중복 생성!
VALUES (1, 'Jonghyun', 'Lim');

SELECT * FROM ftseoul; -- 중복 확인

DELETE FROM ftseoul
WHERE id=1;

SELECT * FROM ftseoul; -- 제거 확인

-- DROP TABLE ftseoul; 하는 방법도 있지만

ALTER TABLE ftseoul
DROP id,
ADD COLUMN id INT AUTO_INCREMENT PRIMARY KEY; -- primary key가 없기에 primary key로 설정 가능. 데이터가 있을 경우 primarykey 정렬 조건이 필요.

INSERT INTO ftseoul(id, first_name, last_name)
VALUES (1, 'jonghyun', 'lim');

INSERT INTO ftseoul(id, first_name, last_name)
VALUES (1, 'jonghyun', 'lim'); -- pk constraint 위배한 오류 발생

INSERT INTO ftseoul(first_name, last_name)
VALUES ('jonghyun', 'lim'); -- 안 들어감

INSERT INTO ftseoul(id, first_name, last_name)
VALUES (1, 'jo', 'lim'); -- 안 들어감

SELECT * FROM ftseoul;

ALTER TABLE ftseoul
ADD COLUMN nickname VARCHAR(32) UNIQUE; -- NOT NULL & UNIQUE 오류 생성

ALTER TABLE ftseoul
ADD COLUMN nickname VARCHAR(32);

UPDATE ftseoul
SET nickname='jolim'
WHERE id=1;

ALTER TABLE ftseoul
ADD CONSTRAINT UNIQUE ftseoul(nickname); -- NOT NULL 안됨... 왜지?

-- 한 번에 하면

DROP TABLE ftseoul;

CREATE SERIAL cadet_serial START WITH 1 INCREMENT BY 1;

CREATE TABLE ftseoul(
  id INT PRIMARY KEY,
  nickname VARCHAR(32) UNIQUE NOT NULL,
  first_name VARCHAR(128) NOT NULL,
  last_name VARCHAR(128) NOT NULL,
  phone_number VARCHAR(16),
  entrance_date DATE DEFAULT CURDATE() -- 왜 DATE만 객체로 만들었을까?
);

INSERT INTO ftseoul(id, nickname, first_name, last_name, phone_number)
VALUES
  (cadet_serial.NEXT_VALUE, 'jolim', 'Jonghyun', 'Lim', '010-0000-0000'),
  (cadet_serial.NEXT_VALUE, 'samin', 'Sanggi', 'Min', '010-0000-0001'),
  (cadet_serial.NEXT_VALUE, 'keokim', 'Keonwoo', 'Kim', '010-0000-0002'),
  (cadet_serial.NEXT_VALUE, 'jseo', 'Jong Hwan', 'Seo', '010-0000-0003'),
  (cadet_serial.NEXT_VALUE, 'jinbekim', 'Jinbeom', 'Kim', '010-0000-0004'),
  (cadet_serial.NEXT_VALUE, 'mchun', 'Minsoo', 'Chun', '010-0000-0005'); -- 여러 개의 데이터 삽입 가능 -- CURRNET_VALUE

CREATE TABLE ecole42 LIKE ftseoul;

INSERT INTO ecole42(id, nickname, first_name, last_name, phone_number)
VALUES
  (cadet_serial.NEXT_VALUE, 'caberfor', 'Clancy', 'Aberforth', '020-0000-0000'),
  (cadet_serial.NEXT_VALUE, 'fdai', 'Florent', 'Dai', '020-0000-0001'),
  (cadet_serial.NEXT_VALUE, 'pabgonza', 'Pablo González', 'Ballesteros', '020-0000-0002'),
  (cadet_serial.NEXT_VALUE, 'zbidouli', 'Zakaria', 'Bidouli', '020-0000-0003');

CREATE TABLE campus(
  id INT PRIMARY KEY AUTO_INCREMENT, -- AUTO_INCREMENT(1, 1) 절에 대해 설명
  campus_name VARCHAR(32) UNIQUE NOT NULL,
  phone_number VARCHAR(16) UNIQUE,
  campus_address VARCHAR(128) UNIQUE
);

INSERT INTO campus(campus_name, phone_number, campus_address)
VALUES
  ('42seoul', '010-212-1311', 'Somewhere in Seoul'),
  ('ecole42', '020-1524-3242', 'Somewhere in Paris'),
  ('1337', '030-1231-4234', 'Somewhere in Morocco'),
  ('school21', '040-7276-445', 'Somewhere in Moscow'),
  ('Codam', '050-1243-4223', 'Somewhere in Amsterdam');

SELECT * FROM campus;

MERGE INTO ftseoul USING ecole42
ON (ftseoul.id = ecole42.id)
--  WHEN MATCHED THEN UPDATE
  WHEN NOT MATCHED THEN INSERT
VALUES (id, nickname, first_name, last_name, phone_number, entrance_date);

RENAME ftseoul TO cadet;
DROP TABLE ecole42;

ALTER TABLE cadet
ADD COLUMN campus_id INT FOREIGN KEY REFERENCES campus(id);

INSERT INTO cadet(id, nickname, first_name, last_name, phone_number, campus_id)
VALUES (cadet_serial.NEXT_VALUE, 'dummy', 'dummis', 'yeah', '000', 10); -- 외부키 조건 때문에 오류 발생

UPDATE cadet
SET campus_id=(
  SELECT id
  FROM campus
  WHERE campus_name='42seoul' -- 42seoul의 아이디를 모른다고 가정
  LIMIT 1
)
WHERE phone_number REGEXP '^(010)';

UPDATE cadet
SET campus_id=(
  SELECT id
  FROM campus
  WHERE campus_name='ecole42'
  LIMIT 1
)
WHERE phone_number REGEXP '^(020)';

/*
** join 쿼리
*/

-- 학생이 있는 캠퍼스의 이름을 얻고싶다.

SELECT campus_name
FROM campus cp
INNER JOIN cadet cd ON cd.campus_id=cp.id; -- 이름이 중복되어 나타난다.

SELECT DISTINCT campus_name -- DISTINCT는 중복을 제거하고 나타내주는 것.
FROM campus cp
INNER JOIN cadet cd ON cd.campus_id=cp.id;

-- 학생이 없는 캠퍼스의 이름을 얻고싶다.

SELECT cp.campus_name, cp.id
FROM campus cp
LEFT JOIN cadet cd ON cd.campus_id=cp.id
WHERE cd.id IS NULL;

/*
 ** ORDER BY
 */

INSERT INTO cadet(id, nickname, first_name, last_name, phone_number, campus_id)
VALUES
  (cadet_serial.NEXT_VALUE, 'oparilov', 'Oleksii', 'Parilov', '030-0000-0004', 3),
  (cadet_serial.NEXT_VALUE, 'leantoni', 'Leaking', 'Antonio', '040-0000-0005', 4),
  (cadet_serial.NEXT_VALUE, 'pohl', 'Paul', 'Ohl', '000-0000-0000', NULL); -- *

-- 캠퍼스 별로, 캠퍼스 아이디 순서대로, 같은 캠퍼스 내에서는 닉네임 순으로 캠퍼스 명과 닉네임이 정렬되게 하고싶다.

SELECT cd.nickname, cp.campus_name
FROM cadet cd
INNER JOIN campus cp ON cd.campus_id=cp.id
ORDER BY
  cp.id,
  cd.nickname; -- pohl이 보이지 않는다.

SELECT cd.nickname, cp.campus_name
FROM cadet cd
LEFT JOIN campus cp ON cd.campus_id=cp.id
ORDER BY
  cp.id,
  cd.nickname; -- pohl이 제일 먼저 온다.

SELECT cd.nickname, cp.campus_name
FROM cadet cd
LEFT JOIN campus cp ON cd.campus_id=cp.id
ORDER BY
  cp.id NULLS LAST,
  cd.nickname; -- pohl이 제일 나중에 온다.

-- 학생이 없는 campus도 나오게 하고 싶다.

SELECT cd.nickname, cp.campus_name
FROM cadet cd
RIGHT JOIN campus cp ON cd.campus_id=cp.id
ORDER BY
  cp.id
  cd.nickname NULLS LAST;

-- 둘 다 나오게 하고싶다 -> full outer join. 큐브리드에서 지원하지 않음.

SELECT cd.nickname, cp.campus_name
FROM cadet cd
LEFT JOIN campus cp ON cd.campus_id=cp.id
UNION
SELECT cd.nickname, cp.campus_name
FROM cadet cd
RIGHT JOIN campus cp ON cd.campus_id=cp.id
ORDER BY
  cp.campus_name NULLS FIRST,
  cd.nickname NULLS FIRST;

