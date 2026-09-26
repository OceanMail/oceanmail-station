use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    env,
    error::Error,
    fs, io,
    net::SocketAddr,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::process::Command;
use uuid::Uuid;

pub mod auth;
pub mod lease;

pub type AnyError = Box<dyn Error + Send + Sync>;

pub const API_VERSION: &str = "v1";
pub const SERVICE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct StationCapabilities {
    pub mail_submission: &'static str,
    pub mail_retrieval: &'static str,
    pub outbound_queue_observation: &'static str,
    pub constrained_transport: &'static str,
    pub queue_mutation: bool,
    pub api_authentication: bool,
    pub lan_exposure: bool,
}

impl Default for StationCapabilities {
    fn default() -> Self {
        Self {
            mail_submission: "smtp",
            mail_retrieval: "imap",
            outbound_queue_observation: "postfix-json-lines",
            constrained_transport: "hermes-mercury",
            queue_mutation: false,
            api_authentication: false,
            lan_exposure: false,
        }
    }
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct StationRecord {
    pub station_id: String,
    pub station_name: String,
    pub created_at_unix: i64,
    pub api_version: &'static str,
    pub service_version: &'static str,
    pub capabilities: StationCapabilities,
}

#[derive(Clone, Debug)]
pub struct AppState {
    pub station: StationRecord,
    pub postqueue_path: PathBuf,
    pub state_db_path: PathBuf,
}

#[derive(Debug, Serialize)]
pub struct HealthResponse {
    pub status: &'static str,
    pub service: &'static str,
    pub api_version: &'static str,
    pub service_version: &'static str,
    pub station_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct QueueRecipient {
    pub address: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delay_reason: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct OutboundQueueEntry {
    pub observation_id: String,
    pub queue_name: String,
    pub queue_id: String,
    pub arrival_time_unix: i64,
    pub message_size: i64,
    pub sender: String,
    pub recipients: Vec<QueueRecipient>,
    pub delivery_state: String,
}

#[derive(Debug, Serialize)]
pub struct OutboundQueueSnapshot {
    pub source: &'static str,
    pub observed_at_unix: i64,
    pub entries: Vec<OutboundQueueEntry>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct OutboundQueueHistoryJob {
    pub observation_id: String,
    pub queue_id: String,
    pub arrival_time_unix: i64,
    pub first_seen_at_unix: i64,
    pub last_seen_at_unix: i64,
    pub last_queue_name: String,
    pub last_delivery_state: String,
    pub sender: String,
    pub message_size: i64,
    pub recipients: Vec<QueueRecipient>,
    pub present_in_postfix: bool,
    pub left_postfix_at_unix: Option<i64>,
    pub evidence_state: String,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct OutboundQueueEvent {
    pub event_id: i64,
    pub observation_id: String,
    pub observed_at_unix: i64,
    pub event_type: String,
    pub queue_name: Option<String>,
    pub delivery_state: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct OutboundQueueHistory {
    pub source: &'static str,
    pub jobs: Vec<OutboundQueueHistoryJob>,
    pub events: Vec<OutboundQueueEvent>,
}

#[derive(Debug, Deserialize)]
struct PostfixQueueRecipient {
    address: String,
    #[serde(default)]
    delay_reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PostfixQueueEntry {
    queue_name: String,
    queue_id: String,
    arrival_time: i64,
    message_size: i64,
    sender: String,
    #[serde(default)]
    recipients: Vec<PostfixQueueRecipient>,
}

#[derive(Debug)]
enum ApiError {
    ServiceUnavailable(String),
}

#[derive(Debug, Serialize)]
struct ErrorBody {
    error: &'static str,
    message: String,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        match self {
            ApiError::ServiceUnavailable(message) => (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(ErrorBody {
                    error: "service_unavailable",
                    message,
                }),
            )
                .into_response(),
        }
    }
}

pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/api/v1/health", get(health))
        .route("/api/v1/station", get(station))
        .route("/api/v1/queues/outbound", get(outbound_queue))
        .route(
            "/api/v1/queues/outbound/history",
            get(outbound_queue_history),
        )
        .with_state(state)
}

async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        service: "oceanmail-station",
        api_version: API_VERSION,
        service_version: SERVICE_VERSION,
        station_id: state.station.station_id,
    })
}

async fn station(State(state): State<AppState>) -> Json<StationRecord> {
    Json(state.station)
}

async fn outbound_queue(
    State(state): State<AppState>,
) -> Result<Json<OutboundQueueSnapshot>, ApiError> {
    let output = Command::new(&state.postqueue_path)
        .arg("-j")
        .output()
        .await
        .map_err(|err| {
            ApiError::ServiceUnavailable(format!(
                "cannot execute {}: {err}",
                state.postqueue_path.display()
            ))
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(ApiError::ServiceUnavailable(format!(
            "{} -j exited with {}{}",
            state.postqueue_path.display(),
            output.status,
            if stderr.is_empty() {
                String::new()
            } else {
                format!(": {stderr}")
            }
        )));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let entries = parse_postqueue_json_lines(&stdout, &state.station.station_id)
        .map_err(ApiError::ServiceUnavailable)?;
    let observed_at_unix = now_unix();

    reconcile_outbound_snapshot(&state.state_db_path, &entries, observed_at_unix).map_err(
        |err| ApiError::ServiceUnavailable(format!("cannot persist queue evidence: {err}")),
    )?;

    Ok(Json(OutboundQueueSnapshot {
        source: "postfix",
        observed_at_unix,
        entries,
    }))
}

async fn outbound_queue_history(
    State(state): State<AppState>,
) -> Result<Json<OutboundQueueHistory>, ApiError> {
    load_outbound_history(&state.state_db_path)
        .map(Json)
        .map_err(|err| ApiError::ServiceUnavailable(format!("cannot load queue history: {err}")))
}

pub fn parse_postqueue_json_lines(
    input: &str,
    station_id: &str,
) -> Result<Vec<OutboundQueueEntry>, String> {
    let mut entries = Vec::new();

    for (index, line) in input.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        let raw: PostfixQueueEntry = serde_json::from_str(line)
            .map_err(|err| format!("invalid postqueue JSON on line {}: {err}", index + 1))?;

        let delivery_state = classify_queue_state(&raw.queue_name).to_string();
        let observation_id = format!("{station_id}:postfix:{}:{}", raw.queue_id, raw.arrival_time);

        entries.push(OutboundQueueEntry {
            observation_id,
            queue_name: raw.queue_name,
            queue_id: raw.queue_id,
            arrival_time_unix: raw.arrival_time,
            message_size: raw.message_size,
            sender: raw.sender,
            recipients: raw
                .recipients
                .into_iter()
                .map(|recipient| QueueRecipient {
                    address: recipient.address,
                    delay_reason: recipient.delay_reason,
                })
                .collect(),
            delivery_state,
        });
    }

    Ok(entries)
}

fn classify_queue_state(queue_name: &str) -> &'static str {
    match queue_name {
        "active" => "selected_for_delivery",
        "deferred" => "deferred",
        "hold" => "held",
        "corrupt" => "error",
        "incoming" | "maildrop" => "queued",
        _ => "queued",
    }
}

pub fn initialize_station(db_path: &Path, requested_name: &str) -> Result<StationRecord, AnyError> {
    if let Some(parent) = db_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let mut connection = Connection::open(db_path)?;
    initialize_schema(&connection)?;
    let transaction = connection.transaction()?;

    let station_id =
        metadata_get(&transaction, "station_id")?.unwrap_or_else(|| Uuid::new_v4().to_string());
    metadata_put_if_absent(&transaction, "station_id", &station_id)?;

    let station_name =
        metadata_get(&transaction, "station_name")?.unwrap_or_else(|| requested_name.to_string());
    metadata_put_if_absent(&transaction, "station_name", &station_name)?;

    let created_at_unix = match metadata_get(&transaction, "created_at_unix")? {
        Some(value) => value.parse::<i64>()?,
        None => {
            let now = now_unix();
            metadata_put_if_absent(&transaction, "created_at_unix", &now.to_string())?;
            now
        }
    };

    transaction.commit()?;

    Ok(StationRecord {
        station_id,
        station_name,
        created_at_unix,
        api_version: API_VERSION,
        service_version: SERVICE_VERSION,
        capabilities: StationCapabilities::default(),
    })
}

fn initialize_schema(connection: &Connection) -> Result<(), AnyError> {
    connection.execute_batch(
        "PRAGMA journal_mode=WAL;\n\
         PRAGMA foreign_keys=ON;\n\
         CREATE TABLE IF NOT EXISTS station_metadata (\n\
             key TEXT PRIMARY KEY NOT NULL,\n\
             value TEXT NOT NULL\n\
         );\n\
         CREATE TABLE IF NOT EXISTS observed_outbound_jobs (\n\
             observation_id TEXT PRIMARY KEY NOT NULL,\n\
             queue_id TEXT NOT NULL,\n\
             arrival_time_unix INTEGER NOT NULL,\n\
             first_seen_at_unix INTEGER NOT NULL,\n\
             last_seen_at_unix INTEGER NOT NULL,\n\
             last_queue_name TEXT NOT NULL,\n\
             last_delivery_state TEXT NOT NULL,\n\
             sender TEXT NOT NULL,\n\
             message_size INTEGER NOT NULL,\n\
             recipients_json TEXT NOT NULL,\n\
             present_in_postfix INTEGER NOT NULL,\n\
             left_postfix_at_unix INTEGER\n\
         );\n\
         CREATE TABLE IF NOT EXISTS observed_outbound_events (\n\
             event_id INTEGER PRIMARY KEY AUTOINCREMENT,\n\
             observation_id TEXT NOT NULL,\n\
             observed_at_unix INTEGER NOT NULL,\n\
             event_type TEXT NOT NULL,\n\
             queue_name TEXT,\n\
             delivery_state TEXT,\n\
             FOREIGN KEY(observation_id) REFERENCES observed_outbound_jobs(observation_id)\n\
         );\n\
         CREATE INDEX IF NOT EXISTS observed_outbound_events_observation_idx\n\
             ON observed_outbound_events(observation_id, event_id);",
    )?;
    Ok(())
}

pub fn reconcile_outbound_snapshot(
    db_path: &Path,
    entries: &[OutboundQueueEntry],
    observed_at_unix: i64,
) -> Result<(), AnyError> {
    let mut connection = Connection::open(db_path)?;
    initialize_schema(&connection)?;
    let transaction = connection.transaction()?;

    let current_ids: HashSet<&str> = entries
        .iter()
        .map(|entry| entry.observation_id.as_str())
        .collect();

    for entry in entries {
        let recipients_json = serde_json::to_string(&entry.recipients)?;
        let existing: Option<(String, String, i64)> = transaction
            .query_row(
                "SELECT last_queue_name, last_delivery_state, present_in_postfix\n\
                 FROM observed_outbound_jobs WHERE observation_id = ?1",
                params![entry.observation_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;

        match existing {
            None => {
                transaction.execute(
                    "INSERT INTO observed_outbound_jobs(\n\
                         observation_id, queue_id, arrival_time_unix, first_seen_at_unix,\n\
                         last_seen_at_unix, last_queue_name, last_delivery_state, sender,\n\
                         message_size, recipients_json, present_in_postfix, left_postfix_at_unix\n\
                     ) VALUES (?1, ?2, ?3, ?4, ?4, ?5, ?6, ?7, ?8, ?9, 1, NULL)",
                    params![
                        entry.observation_id,
                        entry.queue_id,
                        entry.arrival_time_unix,
                        observed_at_unix,
                        entry.queue_name,
                        entry.delivery_state,
                        entry.sender,
                        entry.message_size,
                        recipients_json,
                    ],
                )?;
                insert_outbound_event(
                    &transaction,
                    &entry.observation_id,
                    observed_at_unix,
                    "first_seen",
                    Some(&entry.queue_name),
                    Some(&entry.delivery_state),
                )?;
            }
            Some((last_queue_name, last_delivery_state, present_in_postfix)) => {
                transaction.execute(
                    "UPDATE observed_outbound_jobs SET\n\
                         last_seen_at_unix = ?2, last_queue_name = ?3,\n\
                         last_delivery_state = ?4, sender = ?5, message_size = ?6,\n\
                         recipients_json = ?7, present_in_postfix = 1,\n\
                         left_postfix_at_unix = NULL\n\
                     WHERE observation_id = ?1",
                    params![
                        entry.observation_id,
                        observed_at_unix,
                        entry.queue_name,
                        entry.delivery_state,
                        entry.sender,
                        entry.message_size,
                        recipients_json,
                    ],
                )?;

                if present_in_postfix == 0 {
                    insert_outbound_event(
                        &transaction,
                        &entry.observation_id,
                        observed_at_unix,
                        "reappeared",
                        Some(&entry.queue_name),
                        Some(&entry.delivery_state),
                    )?;
                } else if last_queue_name != entry.queue_name
                    || last_delivery_state != entry.delivery_state
                {
                    insert_outbound_event(
                        &transaction,
                        &entry.observation_id,
                        observed_at_unix,
                        "queue_state_changed",
                        Some(&entry.queue_name),
                        Some(&entry.delivery_state),
                    )?;
                }
            }
        }
    }

    let mut statement = transaction.prepare(
        "SELECT observation_id, last_queue_name, last_delivery_state\n\
         FROM observed_outbound_jobs WHERE present_in_postfix = 1",
    )?;
    let present_rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);

    for (observation_id, queue_name, delivery_state) in present_rows {
        if current_ids.contains(observation_id.as_str()) {
            continue;
        }

        transaction.execute(
            "UPDATE observed_outbound_jobs SET\n\
                 present_in_postfix = 0, left_postfix_at_unix = ?2\n\
             WHERE observation_id = ?1",
            params![observation_id, observed_at_unix],
        )?;
        insert_outbound_event(
            &transaction,
            &observation_id,
            observed_at_unix,
            "left_postfix_queue",
            Some(&queue_name),
            Some(&delivery_state),
        )?;
    }

    transaction.commit()?;
    Ok(())
}

fn insert_outbound_event(
    transaction: &Transaction<'_>,
    observation_id: &str,
    observed_at_unix: i64,
    event_type: &str,
    queue_name: Option<&str>,
    delivery_state: Option<&str>,
) -> rusqlite::Result<()> {
    transaction.execute(
        "INSERT INTO observed_outbound_events(\n\
             observation_id, observed_at_unix, event_type, queue_name, delivery_state\n\
         ) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            observation_id,
            observed_at_unix,
            event_type,
            queue_name,
            delivery_state
        ],
    )?;
    Ok(())
}

pub fn load_outbound_history(db_path: &Path) -> Result<OutboundQueueHistory, AnyError> {
    let connection = Connection::open(db_path)?;
    initialize_schema(&connection)?;

    let mut job_statement = connection.prepare(
        "SELECT observation_id, queue_id, arrival_time_unix, first_seen_at_unix,\n\
                last_seen_at_unix, last_queue_name, last_delivery_state, sender,\n\
                message_size, recipients_json, present_in_postfix, left_postfix_at_unix\n\
         FROM observed_outbound_jobs ORDER BY first_seen_at_unix, observation_id",
    )?;
    let raw_jobs = job_statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, String>(7)?,
                row.get::<_, i64>(8)?,
                row.get::<_, String>(9)?,
                row.get::<_, i64>(10)?,
                row.get::<_, Option<i64>>(11)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;

    let mut jobs = Vec::with_capacity(raw_jobs.len());
    for raw in raw_jobs {
        let recipients: Vec<QueueRecipient> = serde_json::from_str(&raw.9)?;
        let present_in_postfix = raw.10 != 0;
        jobs.push(OutboundQueueHistoryJob {
            observation_id: raw.0,
            queue_id: raw.1,
            arrival_time_unix: raw.2,
            first_seen_at_unix: raw.3,
            last_seen_at_unix: raw.4,
            last_queue_name: raw.5,
            last_delivery_state: raw.6,
            sender: raw.7,
            message_size: raw.8,
            recipients,
            present_in_postfix,
            left_postfix_at_unix: raw.11,
            evidence_state: if present_in_postfix {
                "present_in_postfix".to_string()
            } else {
                "left_postfix_queue".to_string()
            },
        });
    }

    let mut event_statement = connection.prepare(
        "SELECT event_id, observation_id, observed_at_unix, event_type,\n\
                queue_name, delivery_state\n\
         FROM observed_outbound_events ORDER BY event_id",
    )?;
    let events = event_statement
        .query_map([], |row| {
            Ok(OutboundQueueEvent {
                event_id: row.get(0)?,
                observation_id: row.get(1)?,
                observed_at_unix: row.get(2)?,
                event_type: row.get(3)?,
                queue_name: row.get(4)?,
                delivery_state: row.get(5)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;

    Ok(OutboundQueueHistory {
        source: "station-sqlite-postfix-evidence",
        jobs,
        events,
    })
}

fn metadata_get(transaction: &Transaction<'_>, key: &str) -> rusqlite::Result<Option<String>> {
    transaction
        .query_row(
            "SELECT value FROM station_metadata WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()
}

fn metadata_put_if_absent(
    transaction: &Transaction<'_>,
    key: &str,
    value: &str,
) -> rusqlite::Result<()> {
    transaction.execute(
        "INSERT OR IGNORE INTO station_metadata(key, value) VALUES (?1, ?2)",
        params![key, value],
    )?;
    Ok(())
}

pub fn parse_loopback_bind(value: &str) -> Result<SocketAddr, AnyError> {
    let address: SocketAddr = value.parse()?;
    if !address.ip().is_loopback() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "Phase 4 refuses non-loopback API bind {address}; authentication/LAN exposure are not implemented"
            ),
        )
        .into());
    }
    Ok(address)
}

pub fn default_state_db_path() -> PathBuf {
    if let Ok(path) = env::var("OCEANMAIL_STATE_DB") {
        return PathBuf::from(path);
    }

    if let Ok(base) = env::var("XDG_STATE_HOME") {
        return PathBuf::from(base)
            .join("oceanmail-station")
            .join("station.db");
    }

    if let Ok(home) = env::var("HOME") {
        return PathBuf::from(home)
            .join(".local")
            .join("state")
            .join("oceanmail-station")
            .join("station.db");
    }

    PathBuf::from("station.db")
}

pub fn default_station_name() -> String {
    env::var("OCEANMAIL_STATION_NAME")
        .or_else(|_| env::var("HOSTNAME"))
        .unwrap_or_else(|_| "oceanmail-station".to_string())
}

pub fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn station_identity_survives_restart() {
        let root = env::temp_dir().join(format!("oceanmail-station-test-{}", Uuid::new_v4()));
        let db = root.join("station.db");

        let first = initialize_station(&db, "first-name").expect("first initialization");
        let second = initialize_station(&db, "different-name").expect("second initialization");

        assert_eq!(first.station_id, second.station_id);
        assert_eq!(first.station_name, "first-name");
        assert_eq!(second.station_name, "first-name");
        assert_eq!(first.created_at_unix, second.created_at_unix);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn parses_postfix_json_lines_and_ignores_unknown_fields() {
        let input = concat!(
            "{\"queue_name\":\"deferred\",\"queue_id\":\"ABC123\",\"arrival_time\":1700000000,\"message_size\":572,\"sender\":\"alice@stationa.test\",\"future_field\":true,\"recipients\":[{\"address\":\"bob@stationb.test\",\"delay_reason\":\"deferred transport\"}]}\n",
            "{\"queue_name\":\"active\",\"queue_id\":\"XYZ789\",\"arrival_time\":1700000010,\"message_size\":640,\"sender\":\"carol@stationa.test\",\"recipients\":[{\"address\":\"dave@stationb.test\"}]}\n"
        );

        let entries = parse_postqueue_json_lines(input, "station-uuid").expect("parse queue");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].delivery_state, "deferred");
        assert_eq!(
            entries[0].recipients[0].delay_reason.as_deref(),
            Some("deferred transport")
        );
        assert_eq!(entries[1].delivery_state, "selected_for_delivery");
        assert!(entries[1].observation_id.contains("XYZ789"));
    }

    #[test]
    fn observation_id_survives_postfix_queue_state_transition() {
        let deferred = "{\"queue_name\":\"deferred\",\"queue_id\":\"ABC123\",\"arrival_time\":1700000000,\"message_size\":572,\"sender\":\"alice@stationa.test\",\"recipients\":[{\"address\":\"bob@stationb.test\"}]}\n";
        let active = "{\"queue_name\":\"active\",\"queue_id\":\"ABC123\",\"arrival_time\":1700000000,\"message_size\":572,\"sender\":\"alice@stationa.test\",\"recipients\":[{\"address\":\"bob@stationb.test\"}]}\n";

        let deferred_entry = parse_postqueue_json_lines(deferred, "station-uuid")
            .expect("parse deferred")
            .remove(0);
        let active_entry = parse_postqueue_json_lines(active, "station-uuid")
            .expect("parse active")
            .remove(0);

        assert_eq!(deferred_entry.observation_id, active_entry.observation_id);
        assert_eq!(deferred_entry.delivery_state, "deferred");
        assert_eq!(active_entry.delivery_state, "selected_for_delivery");
    }

    #[test]
    fn durable_history_records_evidence_without_claiming_delivery() {
        let root = env::temp_dir().join(format!("oceanmail-history-test-{}", Uuid::new_v4()));
        let db = root.join("station.db");
        let station = initialize_station(&db, "history-test").expect("initialize station");

        let deferred = "{\"queue_name\":\"deferred\",\"queue_id\":\"ABC123\",\"arrival_time\":1700000000,\"message_size\":572,\"sender\":\"alice@stationa.test\",\"recipients\":[{\"address\":\"bob@stationb.test\"}]}\n";
        let active = "{\"queue_name\":\"active\",\"queue_id\":\"ABC123\",\"arrival_time\":1700000000,\"message_size\":572,\"sender\":\"alice@stationa.test\",\"recipients\":[{\"address\":\"bob@stationb.test\"}]}\n";

        let deferred_entries = parse_postqueue_json_lines(deferred, &station.station_id).unwrap();
        reconcile_outbound_snapshot(&db, &deferred_entries, 100).unwrap();

        let active_entries = parse_postqueue_json_lines(active, &station.station_id).unwrap();
        reconcile_outbound_snapshot(&db, &active_entries, 110).unwrap();
        reconcile_outbound_snapshot(&db, &[], 120).unwrap();

        let history_after_leave = load_outbound_history(&db).unwrap();
        assert_eq!(history_after_leave.jobs.len(), 1);
        let job = &history_after_leave.jobs[0];
        assert!(!job.present_in_postfix);
        assert_eq!(job.first_seen_at_unix, 100);
        assert_eq!(job.last_seen_at_unix, 110);
        assert_eq!(job.left_postfix_at_unix, Some(120));
        assert_eq!(job.evidence_state, "left_postfix_queue");
        assert_eq!(job.last_delivery_state, "selected_for_delivery");
        assert_eq!(
            history_after_leave
                .events
                .iter()
                .map(|event| event.event_type.as_str())
                .collect::<Vec<_>>(),
            vec!["first_seen", "queue_state_changed", "left_postfix_queue"]
        );
        assert!(history_after_leave
            .events
            .iter()
            .all(|event| !event.event_type.contains("delivered")
                && !event.event_type.contains("transmitted")));

        reconcile_outbound_snapshot(&db, &deferred_entries, 130).unwrap();
        let history_after_return = load_outbound_history(&db).unwrap();
        assert!(history_after_return.jobs[0].present_in_postfix);
        assert_eq!(history_after_return.jobs[0].left_postfix_at_unix, None);
        assert_eq!(
            history_after_return.events.last().unwrap().event_type,
            "reappeared"
        );

        let reopened = load_outbound_history(&db).unwrap();
        assert_eq!(reopened.jobs.len(), 1);
        assert_eq!(reopened.events.len(), 4);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn empty_postfix_queue_is_valid() {
        let entries = parse_postqueue_json_lines("\n", "station-uuid").expect("empty queue");
        assert!(entries.is_empty());
    }

    #[test]
    fn loopback_binding_is_required() {
        assert!(parse_loopback_bind("127.0.0.1:8080").is_ok());
        assert!(parse_loopback_bind("[::1]:8080").is_ok());
        assert!(parse_loopback_bind("0.0.0.0:8080").is_err());
    }
}
