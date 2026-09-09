CREATE TABLE registration_events (
  accepted_at INTEGER NOT NULL,
  source_bucket TEXT NOT NULL
) STRICT;

CREATE INDEX registration_events_time
  ON registration_events(accepted_at);

CREATE INDEX registration_events_source_time
  ON registration_events(source_bucket, accepted_at);
