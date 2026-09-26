use oceanmail_station::{default_state_db_path, now_unix, AnyError};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::Serialize;
use std::{
    env, fs, io,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
struct UucpJobEvidence {
    observation_id: String,
    postfix_queue_id: String,
    remote_system: String,
    uucp_job_id: String,
    uucp_command: String,
    queued_bytes: i64,
    observed_at_unix: i64,
    evidence_type: &'static str,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
struct UucpTransportAttempt {
    attempt_id: String,
    remote_system: String,
    adapter: String,
    started_at_unix: i64,
    finished_at_unix: Option<i64>,
    process_exit_code: Option<i64>,
    process_outcome: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
struct UucpAttemptJobEvidence {
    attempt_id: String,
    observation_id: String,
    remote_system: String,
    uucp_job_id: String,
    relationship: &'static str,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
struct UucpTransportAttemptEvent {
    event_id: i64,
    attempt_id: String,
    observed_at_unix: i64,
    event_type: String,
    evidence_source: Option<String>,
    metric_name: Option<String>,
    metric_value: Option<i64>,
    detail: Option<String>,
}

#[derive(Debug, Serialize)]
struct UucpEvidenceList {
    source: &'static str,
    jobs: Vec<UucpJobEvidence>,
    attempts: Vec<UucpTransportAttempt>,
    attempt_jobs: Vec<UucpAttemptJobEvidence>,
    attempt_events: Vec<UucpTransportAttemptEvent>,
}

fn main() -> Result<(), AnyError> {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("record") => record_command(&args[1..]),
        Some("attempt-start") => attempt_start_command(&args[1..]),
        Some("attempt-snapshot") => attempt_snapshot_command(&args[1..]),
        Some("attempt-progress") => attempt_progress_command(&args[1..]),
        Some("attempt-finish") => attempt_finish_command(&args[1..]),
        Some("list") => list_command(&args[1..]),
        _ => Err(usage_error()),
    }
}

fn record_command(args: &[String]) -> Result<(), AnyError> {
    let db_path = state_db_from_args(args)?;
    let postfix_queue_id = required_flag(args, "--postfix-queue-id")?;
    let remote_system = required_flag(args, "--remote-system")?;
    let uucp_job_id = required_flag(args, "--uucp-job-id")?;
    let uucp_command = required_flag(args, "--command")?;
    let queued_bytes =
        parse_nonnegative_i64(&required_flag(args, "--queued-bytes")?, "--queued-bytes")?;

    let record = record_uucp_job(
        &db_path,
        &postfix_queue_id,
        &remote_system,
        &uucp_job_id,
        &uucp_command,
        queued_bytes,
        now_unix(),
    )?;
    println!("{}", serde_json::to_string(&record)?);
    Ok(())
}

fn attempt_start_command(args: &[String]) -> Result<(), AnyError> {
    let db_path = state_db_from_args(args)?;
    let attempt_id = required_flag(args, "--attempt-id")?;
    let remote_system = required_flag(args, "--remote-system")?;
    let adapter = required_flag(args, "--adapter")?;
    let attempt =
        record_attempt_start(&db_path, &attempt_id, &remote_system, &adapter, now_unix())?;
    println!("{}", serde_json::to_string(&attempt)?);
    Ok(())
}

fn attempt_snapshot_command(args: &[String]) -> Result<(), AnyError> {
    let db_path = state_db_from_args(args)?;
    let attempt_id = required_flag(args, "--attempt-id")?;
    let remote_system = required_flag(args, "--remote-system")?;
    let uustat_file = PathBuf::from(required_flag(args, "--uustat-file")?);
    let snapshot = record_attempt_snapshot(&db_path, &attempt_id, &remote_system, &uustat_file)?;
    println!("{}", serde_json::to_string(&snapshot)?);
    Ok(())
}

fn attempt_progress_command(args: &[String]) -> Result<(), AnyError> {
    let db_path = state_db_from_args(args)?;
    let attempt_id = required_flag(args, "--attempt-id")?;
    let source = required_flag(args, "--source")?;
    let metric_name = required_flag(args, "--metric-name")?;
    let metric_value =
        parse_nonnegative_i64(&required_flag(args, "--metric-value")?, "--metric-value")?;
    let detail = optional_flag(args, "--detail")?;
    let event = record_attempt_progress(
        &db_path,
        &attempt_id,
        &source,
        &metric_name,
        metric_value,
        detail.as_deref(),
        now_unix(),
    )?;
    println!("{}", serde_json::to_string(&event)?);
    Ok(())
}

fn attempt_finish_command(args: &[String]) -> Result<(), AnyError> {
    let db_path = state_db_from_args(args)?;
    let attempt_id = required_flag(args, "--attempt-id")?;
    let exit_code = required_flag(args, "--exit-code")?
        .parse::<i64>()
        .map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("invalid --exit-code: {err}"),
            )
        })?;
    let attempt = record_attempt_finish(&db_path, &attempt_id, exit_code, now_unix())?;
    println!("{}", serde_json::to_string(&attempt)?);
    Ok(())
}

fn list_command(args: &[String]) -> Result<(), AnyError> {
    let db_path = state_db_from_args(args)?;
    initialize_schema(&db_path)?;
    let connection = open_connection(&db_path)?;
    let output = UucpEvidenceList {
        source: "station-sqlite-uucp-evidence",
        jobs: load_jobs(&connection)?,
        attempts: load_attempts(&connection)?,
        attempt_jobs: load_attempt_jobs(&connection)?,
        attempt_events: load_attempt_events(&connection)?,
    };
    println!("{}", serde_json::to_string(&output)?);
    Ok(())
}

fn state_db_from_args(args: &[String]) -> Result<PathBuf, AnyError> {
    match optional_flag(args, "--state-db")? {
        Some(path) => Ok(PathBuf::from(path)),
        None => Ok(default_state_db_path()),
    }
}

fn required_flag(args: &[String], flag: &str) -> Result<String, AnyError> {
    optional_flag(args, flag)?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("missing required flag {flag}"),
        )
        .into()
    })
}

fn optional_flag(args: &[String], flag: &str) -> Result<Option<String>, AnyError> {
    let Some(index) = args.iter().position(|arg| arg == flag) else {
        return Ok(None);
    };
    let Some(value) = args.get(index + 1) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("missing value for {flag}"),
        )
        .into());
    };
    if value.starts_with("--") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("missing value for {flag}"),
        )
        .into());
    }
    Ok(Some(value.clone()))
}

fn parse_nonnegative_i64(value: &str, flag: &str) -> Result<i64, AnyError> {
    let parsed = value.parse::<i64>().map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid {flag}: {err}"),
        )
    })?;
    if parsed < 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{flag} must be non-negative"),
        )
        .into());
    }
    Ok(parsed)
}

fn usage_error() -> AnyError {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "usage: oceanmail-uucp-evidence record ... | attempt-start ... | attempt-snapshot ... | attempt-progress ... | attempt-finish ... | list [--state-db PATH]",
    )
    .into()
}

fn open_connection(db_path: &Path) -> Result<Connection, AnyError> {
    let connection = Connection::open(db_path)?;
    connection.busy_timeout(std::time::Duration::from_secs(5))?;
    connection.execute_batch("PRAGMA foreign_keys=ON;")?;
    Ok(connection)
}

fn initialize_schema(db_path: &Path) -> Result<(), AnyError> {
    let connection = open_connection(db_path)?;
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS observed_uucp_jobs (\n\
             remote_system TEXT NOT NULL,\n\
             uucp_job_id TEXT NOT NULL,\n\
             observation_id TEXT NOT NULL,\n\
             postfix_queue_id TEXT NOT NULL,\n\
             uucp_command TEXT NOT NULL,\n\
             queued_bytes INTEGER NOT NULL,\n\
             observed_at_unix INTEGER NOT NULL,\n\
             PRIMARY KEY(remote_system, uucp_job_id),\n\
             FOREIGN KEY(observation_id) REFERENCES observed_outbound_jobs(observation_id)\n\
         );\n\
         CREATE INDEX IF NOT EXISTS observed_uucp_jobs_observation_idx\n\
             ON observed_uucp_jobs(observation_id, observed_at_unix);\n\
         CREATE TABLE IF NOT EXISTS observed_uucp_transport_attempts (\n\
             attempt_id TEXT PRIMARY KEY NOT NULL,\n\
             remote_system TEXT NOT NULL,\n\
             adapter TEXT NOT NULL,\n\
             started_at_unix INTEGER NOT NULL,\n\
             finished_at_unix INTEGER,\n\
             process_exit_code INTEGER,\n\
             process_outcome TEXT\n\
         );\n\
         CREATE TABLE IF NOT EXISTS observed_uucp_attempt_jobs (\n\
             attempt_id TEXT NOT NULL,\n\
             remote_system TEXT NOT NULL,\n\
             uucp_job_id TEXT NOT NULL,\n\
             observation_id TEXT NOT NULL,\n\
             relationship TEXT NOT NULL,\n\
             PRIMARY KEY(attempt_id, remote_system, uucp_job_id),\n\
             FOREIGN KEY(attempt_id) REFERENCES observed_uucp_transport_attempts(attempt_id),\n\
             FOREIGN KEY(remote_system, uucp_job_id) REFERENCES observed_uucp_jobs(remote_system, uucp_job_id),\n\
             FOREIGN KEY(observation_id) REFERENCES observed_outbound_jobs(observation_id)\n\
         );\n\
         CREATE TABLE IF NOT EXISTS observed_uucp_transport_attempt_events (\n\
             event_id INTEGER PRIMARY KEY AUTOINCREMENT,\n\
             attempt_id TEXT NOT NULL,\n\
             observed_at_unix INTEGER NOT NULL,\n\
             event_type TEXT NOT NULL,\n\
             evidence_source TEXT,\n\
             metric_name TEXT,\n\
             metric_value INTEGER,\n\
             detail TEXT,\n\
             FOREIGN KEY(attempt_id) REFERENCES observed_uucp_transport_attempts(attempt_id)\n\
         );\n\
         CREATE INDEX IF NOT EXISTS observed_uucp_attempt_events_idx\n\
             ON observed_uucp_transport_attempt_events(attempt_id, event_id);",
    )?;
    Ok(())
}

fn record_uucp_job(
    db_path: &Path,
    postfix_queue_id: &str,
    remote_system: &str,
    uucp_job_id: &str,
    uucp_command: &str,
    queued_bytes: i64,
    observed_at_unix: i64,
) -> Result<UucpJobEvidence, AnyError> {
    initialize_schema(db_path)?;
    let mut connection = open_connection(db_path)?;
    let transaction = connection.transaction()?;

    if let Some(existing) = load_job(&transaction, remote_system, uucp_job_id)? {
        if existing.postfix_queue_id != postfix_queue_id {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "UUCP job {remote_system}/{uucp_job_id} is already mapped to Postfix queue {}, not {postfix_queue_id}",
                    existing.postfix_queue_id
                ),
            )
            .into());
        }
        if existing.uucp_command != uucp_command || existing.queued_bytes != queued_bytes {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "UUCP job {remote_system}/{uucp_job_id} was re-observed with conflicting command/size evidence"
                ),
            )
            .into());
        }
        transaction.commit()?;
        return Ok(existing);
    }

    let observation_ids = {
        let mut statement = transaction.prepare(
            "SELECT observation_id\n\
             FROM observed_outbound_jobs\n\
             WHERE queue_id = ?1 AND present_in_postfix = 1\n\
             ORDER BY last_seen_at_unix DESC, observation_id",
        )?;
        let rows = statement
            .query_map(params![postfix_queue_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };

    if observation_ids.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "expected exactly one currently-present Postfix observation for queue id {postfix_queue_id}, found {}",
                observation_ids.len()
            ),
        )
        .into());
    }
    let observation_id = observation_ids[0].clone();

    transaction.execute(
        "INSERT INTO observed_uucp_jobs(\n\
             remote_system, uucp_job_id, observation_id, postfix_queue_id,\n\
             uucp_command, queued_bytes, observed_at_unix\n\
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            remote_system,
            uucp_job_id,
            observation_id,
            postfix_queue_id,
            uucp_command,
            queued_bytes,
            observed_at_unix,
        ],
    )?;
    transaction.execute(
        "INSERT INTO observed_outbound_events(\n\
             observation_id, observed_at_unix, event_type, queue_name, delivery_state\n\
         ) VALUES (?1, ?2, 'uucp_job_created', NULL, NULL)",
        params![observation_id, observed_at_unix],
    )?;
    transaction.commit()?;

    Ok(UucpJobEvidence {
        observation_id,
        postfix_queue_id: postfix_queue_id.to_string(),
        remote_system: remote_system.to_string(),
        uucp_job_id: uucp_job_id.to_string(),
        uucp_command: uucp_command.to_string(),
        queued_bytes,
        observed_at_unix,
        evidence_type: "uucp_job_created",
    })
}

fn record_attempt_start(
    db_path: &Path,
    attempt_id: &str,
    remote_system: &str,
    adapter: &str,
    observed_at_unix: i64,
) -> Result<UucpTransportAttempt, AnyError> {
    initialize_schema(db_path)?;
    let mut connection = open_connection(db_path)?;
    let transaction = connection.transaction()?;

    if let Some(existing) = load_attempt(&transaction, attempt_id)? {
        if existing.remote_system != remote_system || existing.adapter != adapter {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("attempt {attempt_id} was re-observed with conflicting identity"),
            )
            .into());
        }
        transaction.commit()?;
        return Ok(existing);
    }

    transaction.execute(
        "INSERT INTO observed_uucp_transport_attempts(\n\
             attempt_id, remote_system, adapter, started_at_unix\n\
         ) VALUES (?1, ?2, ?3, ?4)",
        params![attempt_id, remote_system, adapter, observed_at_unix],
    )?;
    insert_attempt_event(
        &transaction,
        attempt_id,
        observed_at_unix,
        "uucico_attempt_started",
        Some(adapter),
        None,
        None,
        Some("Station invoked a Taylor UUCP caller attempt for the remote system; this is not proof that any specific queued job transmitted bytes."),
    )?;
    transaction.commit()?;
    load_attempt_from_db(db_path, attempt_id)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "new attempt disappeared").into())
}

fn record_attempt_snapshot(
    db_path: &Path,
    attempt_id: &str,
    remote_system: &str,
    uustat_file: &Path,
) -> Result<Vec<UucpAttemptJobEvidence>, AnyError> {
    initialize_schema(db_path)?;
    let contents = fs::read_to_string(uustat_file)?;
    let mut connection = open_connection(db_path)?;
    let transaction = connection.transaction()?;
    let attempt = load_attempt(&transaction, attempt_id)?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("unknown attempt {attempt_id}"),
        )
    })?;
    if attempt.remote_system != remote_system {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "attempt {attempt_id} belongs to {}, not {remote_system}",
                attempt.remote_system
            ),
        )
        .into());
    }

    let mut associated = Vec::new();
    for line in contents.lines() {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        if fields.len() < 2 || fields[1] != remote_system {
            continue;
        }
        let uucp_job_id = fields[0];
        let observation_id: Option<String> = transaction
            .query_row(
                "SELECT observation_id FROM observed_uucp_jobs\n\
                 WHERE remote_system = ?1 AND uucp_job_id = ?2",
                params![remote_system, uucp_job_id],
                |row| row.get(0),
            )
            .optional()?;
        let Some(observation_id) = observation_id else {
            continue;
        };
        transaction.execute(
            "INSERT OR IGNORE INTO observed_uucp_attempt_jobs(\n\
                 attempt_id, remote_system, uucp_job_id, observation_id, relationship\n\
             ) VALUES (?1, ?2, ?3, ?4, 'queued_at_attempt_start')",
            params![attempt_id, remote_system, uucp_job_id, observation_id],
        )?;
        associated.push(UucpAttemptJobEvidence {
            attempt_id: attempt_id.to_string(),
            observation_id,
            remote_system: remote_system.to_string(),
            uucp_job_id: uucp_job_id.to_string(),
            relationship: "queued_at_attempt_start",
        });
    }

    insert_attempt_event(
        &transaction,
        attempt_id,
        now_unix(),
        "queued_job_snapshot_recorded",
        Some("taylor-uustat"),
        Some("mapped_jobs_queued_at_attempt_start"),
        Some(associated.len() as i64),
        Some("Snapshot records which mapped jobs were queued when the system-level caller attempt began; it does not claim each job transmitted."),
    )?;
    transaction.commit()?;
    Ok(associated)
}

fn record_attempt_progress(
    db_path: &Path,
    attempt_id: &str,
    evidence_source: &str,
    metric_name: &str,
    metric_value: i64,
    detail: Option<&str>,
    observed_at_unix: i64,
) -> Result<UucpTransportAttemptEvent, AnyError> {
    initialize_schema(db_path)?;
    let mut connection = open_connection(db_path)?;
    let transaction = connection.transaction()?;
    if load_attempt(&transaction, attempt_id)?.is_none() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("unknown attempt {attempt_id}"),
        )
        .into());
    }
    let event_id = insert_attempt_event(
        &transaction,
        attempt_id,
        observed_at_unix,
        "transport_progress_observed",
        Some(evidence_source),
        Some(metric_name),
        Some(metric_value),
        detail,
    )?;
    transaction.commit()?;
    Ok(UucpTransportAttemptEvent {
        event_id,
        attempt_id: attempt_id.to_string(),
        observed_at_unix,
        event_type: "transport_progress_observed".to_string(),
        evidence_source: Some(evidence_source.to_string()),
        metric_name: Some(metric_name.to_string()),
        metric_value: Some(metric_value),
        detail: detail.map(str::to_string),
    })
}

fn record_attempt_finish(
    db_path: &Path,
    attempt_id: &str,
    exit_code: i64,
    observed_at_unix: i64,
) -> Result<UucpTransportAttempt, AnyError> {
    initialize_schema(db_path)?;
    let mut connection = open_connection(db_path)?;
    let transaction = connection.transaction()?;
    let existing = load_attempt(&transaction, attempt_id)?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("unknown attempt {attempt_id}"),
        )
    })?;
    let outcome = if exit_code == 0 {
        "process_exit_success"
    } else {
        "process_exit_failure"
    };

    if let Some(existing_code) = existing.process_exit_code {
        if existing_code != exit_code {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("attempt {attempt_id} was re-finished with conflicting exit code"),
            )
            .into());
        }
        transaction.commit()?;
        return Ok(existing);
    }

    transaction.execute(
        "UPDATE observed_uucp_transport_attempts SET\n\
             finished_at_unix = ?2, process_exit_code = ?3, process_outcome = ?4\n\
         WHERE attempt_id = ?1",
        params![attempt_id, observed_at_unix, exit_code, outcome],
    )?;
    insert_attempt_event(
        &transaction,
        attempt_id,
        observed_at_unix,
        "uucico_attempt_finished",
        Some("taylor-uucico-process"),
        Some("process_exit_code"),
        Some(exit_code),
        Some(outcome),
    )?;
    transaction.commit()?;
    load_attempt_from_db(db_path, attempt_id)?.ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "finished attempt disappeared").into()
    })
}

fn insert_attempt_event(
    transaction: &Transaction<'_>,
    attempt_id: &str,
    observed_at_unix: i64,
    event_type: &str,
    evidence_source: Option<&str>,
    metric_name: Option<&str>,
    metric_value: Option<i64>,
    detail: Option<&str>,
) -> rusqlite::Result<i64> {
    transaction.execute(
        "INSERT INTO observed_uucp_transport_attempt_events(\n\
             attempt_id, observed_at_unix, event_type, evidence_source,\n\
             metric_name, metric_value, detail\n\
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            attempt_id,
            observed_at_unix,
            event_type,
            evidence_source,
            metric_name,
            metric_value,
            detail
        ],
    )?;
    Ok(transaction.last_insert_rowid())
}

fn load_job(
    connection: &Connection,
    remote_system: &str,
    uucp_job_id: &str,
) -> Result<Option<UucpJobEvidence>, AnyError> {
    connection
        .query_row(
            "SELECT observation_id, postfix_queue_id, remote_system, uucp_job_id,\n\
                    uucp_command, queued_bytes, observed_at_unix\n\
             FROM observed_uucp_jobs\n\
             WHERE remote_system = ?1 AND uucp_job_id = ?2",
            params![remote_system, uucp_job_id],
            |row| {
                Ok(UucpJobEvidence {
                    observation_id: row.get(0)?,
                    postfix_queue_id: row.get(1)?,
                    remote_system: row.get(2)?,
                    uucp_job_id: row.get(3)?,
                    uucp_command: row.get(4)?,
                    queued_bytes: row.get(5)?,
                    observed_at_unix: row.get(6)?,
                    evidence_type: "uucp_job_created",
                })
            },
        )
        .optional()
        .map_err(Into::into)
}

fn load_attempt(
    connection: &Connection,
    attempt_id: &str,
) -> Result<Option<UucpTransportAttempt>, AnyError> {
    connection
        .query_row(
            "SELECT attempt_id, remote_system, adapter, started_at_unix,\n\
                    finished_at_unix, process_exit_code, process_outcome\n\
             FROM observed_uucp_transport_attempts WHERE attempt_id = ?1",
            params![attempt_id],
            |row| {
                Ok(UucpTransportAttempt {
                    attempt_id: row.get(0)?,
                    remote_system: row.get(1)?,
                    adapter: row.get(2)?,
                    started_at_unix: row.get(3)?,
                    finished_at_unix: row.get(4)?,
                    process_exit_code: row.get(5)?,
                    process_outcome: row.get(6)?,
                })
            },
        )
        .optional()
        .map_err(Into::into)
}

fn load_attempt_from_db(
    db_path: &Path,
    attempt_id: &str,
) -> Result<Option<UucpTransportAttempt>, AnyError> {
    let connection = open_connection(db_path)?;
    load_attempt(&connection, attempt_id)
}

fn load_jobs(connection: &Connection) -> Result<Vec<UucpJobEvidence>, AnyError> {
    let mut statement = connection.prepare(
        "SELECT observation_id, postfix_queue_id, remote_system, uucp_job_id,\n\
                uucp_command, queued_bytes, observed_at_unix\n\
         FROM observed_uucp_jobs\n\
         ORDER BY observed_at_unix, remote_system, uucp_job_id",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok(UucpJobEvidence {
                observation_id: row.get(0)?,
                postfix_queue_id: row.get(1)?,
                remote_system: row.get(2)?,
                uucp_job_id: row.get(3)?,
                uucp_command: row.get(4)?,
                queued_bytes: row.get(5)?,
                observed_at_unix: row.get(6)?,
                evidence_type: "uucp_job_created",
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

fn load_attempts(connection: &Connection) -> Result<Vec<UucpTransportAttempt>, AnyError> {
    let mut statement = connection.prepare(
        "SELECT attempt_id, remote_system, adapter, started_at_unix,\n\
                finished_at_unix, process_exit_code, process_outcome\n\
         FROM observed_uucp_transport_attempts\n\
         ORDER BY started_at_unix, attempt_id",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok(UucpTransportAttempt {
                attempt_id: row.get(0)?,
                remote_system: row.get(1)?,
                adapter: row.get(2)?,
                started_at_unix: row.get(3)?,
                finished_at_unix: row.get(4)?,
                process_exit_code: row.get(5)?,
                process_outcome: row.get(6)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

fn load_attempt_jobs(connection: &Connection) -> Result<Vec<UucpAttemptJobEvidence>, AnyError> {
    let mut statement = connection.prepare(
        "SELECT attempt_id, observation_id, remote_system, uucp_job_id\n\
         FROM observed_uucp_attempt_jobs\n\
         WHERE relationship = 'queued_at_attempt_start'\n\
         ORDER BY attempt_id, remote_system, uucp_job_id",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok(UucpAttemptJobEvidence {
                attempt_id: row.get(0)?,
                observation_id: row.get(1)?,
                remote_system: row.get(2)?,
                uucp_job_id: row.get(3)?,
                relationship: "queued_at_attempt_start",
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

fn load_attempt_events(
    connection: &Connection,
) -> Result<Vec<UucpTransportAttemptEvent>, AnyError> {
    let mut statement = connection.prepare(
        "SELECT event_id, attempt_id, observed_at_unix, event_type, evidence_source,\n\
                metric_name, metric_value, detail\n\
         FROM observed_uucp_transport_attempt_events ORDER BY event_id",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok(UucpTransportAttemptEvent {
                event_id: row.get(0)?,
                attempt_id: row.get(1)?,
                observed_at_unix: row.get(2)?,
                event_type: row.get(3)?,
                evidence_source: row.get(4)?,
                metric_name: row.get(5)?,
                metric_value: row.get(6)?,
                detail: row.get(7)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}
