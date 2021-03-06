--
-- Copyright 2020 The Android Open Source Project
--
-- Licensed under the Apache License, Version 2.0 (the 'License');
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an 'AS IS' BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Priority order for RAIL modes where response has the highest priority and
-- idle has the lowest.
CREATE TABLE IF NOT EXISTS rail_modes (MODE STRING UNIQUE, ordering INT);

INSERT
  OR IGNORE INTO rail_modes
VALUES ('idle', 0),
  ('load', 1),
  ('animation', 2),
  ('response', 3);

-- View containing all Scheduler.RAILMode slices across all Chrome renderer
-- processes.
DROP VIEW IF EXISTS rail_mode_slices;
CREATE VIEW rail_mode_slices AS
SELECT slice.id,
  ts,
  CASE
    WHEN dur == -1 THEN trace_bounds.end_ts - ts
    ELSE dur
  END AS dur,
  track_id,
  EXTRACT_ARG(slice.arg_set_id, "debug.state") AS rail_mode
FROM trace_bounds,
  slice
WHERE slice.name = "Scheduler.RAILMode";

-- View containing a collapsed view of rail_mode_slices where there is only one
-- RAIL mode active at a given time. The mode is derived using the priority
-- order in rail_modes.
DROP VIEW IF EXISTS overall_rail_mode_slices;
CREATE VIEW overall_rail_mode_slices AS
SELECT s.ts,
  s.end_ts,
  r.rail_mode,
  MAX(rail_modes.ordering)
FROM (
    SELECT ts,
      LEAD(ts, 1, trace_bounds.end_ts) OVER (
        ORDER BY ts
      ) AS end_ts
    FROM (
        SELECT DISTINCT ts
        FROM rail_mode_slices
      ) start_times,
      trace_bounds
  ) s,
  rail_mode_slices r,
  rail_modes
WHERE (
    (
      s.ts BETWEEN r.ts AND r.ts + r.dur
    )
    OR (
      s.end_ts BETWEEN r.ts AND r.ts + r.dur
    )
  )
  AND r.rail_mode == rail_modes.mode
GROUP BY s.ts;

-- Contains the same data as overall_rail_mode_slices except adjacent slices
-- with the same RAIL mode are combined.
CREATE TABLE IF NOT EXISTS combined_overall_rail_slices AS
SELECT ROW_NUMBER() OVER () AS id,
  ts,
  end_ts - ts AS dur,
  rail_mode
FROM (
    SELECT lag(l.end_ts, 1, FIRST) OVER (
        ORDER BY l.ts
      ) AS ts,
      l.end_ts,
      l.rail_mode
    FROM (
        SELECT ts,
          end_ts,
          rail_mode
        FROM overall_rail_mode_slices s
        WHERE NOT EXISTS (
            SELECT NULL
            FROM overall_rail_mode_slices s2
            WHERE s.rail_mode = s2.rail_mode
              AND s.end_ts = s2.ts
          )
      ) AS l,
      (
        SELECT min(ts) AS FIRST
        FROM overall_rail_mode_slices
      )
  );
