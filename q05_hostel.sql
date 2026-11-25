-- Q5 Hostel Room Allocation (PostgreSQL)

-- (a) Tables
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    room_id INT NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE,
    status VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CHECK ((status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL))
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INT NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT NOT NULL,
    free_beds INT NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
('H001', 'Mulenga Chola'),
('H002', 'Temwani Banda'),
('H003', 'Precious Mwila'),
('H004', 'Kelvin Tembo'),
('H005', 'Linda Ngoma');

INSERT INTO rooms (room_number, capacity) VALUES ('R101', 2), ('R102', 3), ('R103', 2);

-- (b) Function
CREATE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT AS $$
DECLARE v_capacity INT;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room % does not exist', p_room_id;
    END IF;
    RETURN v_capacity - (SELECT COUNT(*) FROM allocations
                         WHERE room_id = p_room_id AND status = 'ACTIVE');
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure
CREATE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student % does not exist', p_student_id;
    END IF;
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room % does not exist', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an active allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (d) Trigger (protects direct inserts and updates too)
CREATE FUNCTION trg_check_allocation() RETURNS TRIGGER AS $$
DECLARE
    v_capacity INT;
    v_taken INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        IF EXISTS (SELECT 1 FROM allocations
                   WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                     AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id)) THEN
            RAISE EXCEPTION 'Student % already has an active allocation', NEW.student_id;
        END IF;

        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        SELECT COUNT(*) INTO v_taken FROM allocations
        WHERE room_id = NEW.room_id AND status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_taken >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full', NEW.room_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_allocations_check
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_check_allocation();

-- (a) Sample allocations
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 1, CURRENT_DATE - 200, CURRENT_DATE - 100, 'ENDED');

CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);   -- R101 full
CALL pr_allocate_room(2, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 10);   -- R102 partly full, R103 empty

-- these should fail
CALL pr_allocate_room(5, 1, CURRENT_DATE);   -- room full
CALL pr_allocate_room(1, 3, CURRENT_DATE);   -- already allocated
INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (5, 1, CURRENT_DATE, 'ACTIVE');

-- (e) View
CREATE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id) AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy;

-- (f) Index (only active allocations are indexed)
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

EXPLAIN SELECT * FROM allocations WHERE room_id = 2 AND status = 'ACTIVE';

-- (g) Scheduled job
CREATE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_occupancy', '55 23 * * *', 'CALL pr_refresh_occupancy()');
