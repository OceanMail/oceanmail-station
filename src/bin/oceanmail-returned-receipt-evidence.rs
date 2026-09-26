use oceanmail_station::{default_state_db_path, now_unix, AnyError};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{
    env, fs, io,
    path::{Path, PathBuf},
};

const RECEIPT_VERSION: u64 = 1;
const RECEIPT_TYPE: &str = "oceanmail.remote_mailbox_receipt";
const LAB_RECEIPT_TRUST_STATE: &str = "lab_peer_transport_unverified";

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
struct MessageIdentityEvidence {
    message_id: String,
    observation_id: String,
    postfix_queue_id: String,
    observed_at_unix: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct ReturnedReceiptArtifact {
    version: u64,
    artifact_type: String,
    message_id: String,
    remote_system: String,
    receipt_kind: String,
    evidence_source: String,
    observed_at_unix: i64,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
struct ReturnedReceiptEvidence {
    observation_id: String,
    postfix_queue_id: String,
    remote_system: String,
    uucp_job_id: String,
    message_id: String,
    receipt_kind: String,
    evidence_source: String,
    trust_state: String,
    artifact_json: String,
    observed_at_unix: i64,
    evidence_type: &'static str,
}

#[derive(Debug, Serialize)]
struct ReturnedReceiptList {
    source: &'static str,
    message_identities: Vec<MessageIdentityEvidence>,
    returned_receipts: Vec<ReturnedReceiptEvidence>,
}

fn main() -> Result<(), AnyError> {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("message-record") => message_record_command(&args[1..]),
        Some("returned-record") => returned_record_command(&args[1..]),
        Some("list") => list_command(&args[1..]),
        _ => Err(usage_error()),
    }
}

fn message_record_command(args: &[String]) -> Result<(), AnyError> {
    let db_path = state_db_from_args(args)?;
    let postfix_queue_id = required_flag(args, "--postfix-queue-id")?;
    let message_id = required_flag(args, "--message-id")?;
    validate_message_id(&message_id)?;
    let record = record_message_identity(&db_path, &postfix_queue_id, &message_id, now_unix())?;
    println!("{}", serde_json::to_string(&record)?);
    Ok(())
}

fn returned_record_command(args: &[String]) -> Result<(), AnyError> {
    let db_path = state_db_from_args(args)?;
    let artifact_path = PathBuf::from(required_flag(args, "--artifact")?);
    let trust_state = required_flag(args, "--trust-state")?;
    validate_trust_state(&trust_state)?;

    let artifact_json = fs::read_to_string(&artifact_path)?;
    let artifact: ReturnedReceiptArtifact = serde_json::from_str(&artifact_json)?;
    validate_artifact(&artifact)?;
    let evidence = record_returned_receipt(
        &db_path,
        &artifact,
        &artifact_json,
        &trust_state,
        now_unix(),
    )?;
    println!("{}", serde_json::to_string(&evidence)?);
    Ok(())
}

fn list_command(args: &[String]) -> Result<(), AnyError> {
    let db_path = state_db_from_args(args)?;
    initialize_schema(&db_path)?;
    let connection = open_connection(&db_path)?;
    let output = ReturnedReceiptList {
        source: "station-sqlite-returned-receipt-evidence",
        message_identities: load_message_identities(&connection)?,
        returned_receipts: load_returned_receipts(&connection)?,
    };
    println!("{}", serde_json::to_string(&output)?);
    Ok(())
}

fn validate_trust_state(trust_state: &str) -> Result<(), AnyError> {
    if trust_state != LAB_RECEIPT_TRUST_STATE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "unsupported trust-state {trust_state:?}; Phase 4I only accepts {LAB_RECEIPT_TRUST_STATE:?}"
            ),
        )
        .into());
    }
    Ok(())
}

fn validate_message_id(message_id: &str) -> Result<(), AnyError> {
    let trimmed = message_id.trim();
    if trimmed.len() < 3
        || !trimmed.starts_with('<')
        || !trimmed.ends_with('>')
        || !trimmed.contains('@')
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "message-id must be a bracketed RFC Message-ID containing @",
        )
        .into());
    }
    Ok(())
}

fn validate_artifact(artifact: &ReturnedReceiptArtifact) -> Result<(), AnyError> {
    if artifact.version != RECEIPT_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unsupported receipt version {}", artifact.version),
        )
        .into());
    }
    if artifact.artifact_type != RECEIPT_TYPE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unexpected artifact type {}", artifact.artifact_type),
        )
        .into());
    }
    validate_message_id(&artifact.message_id)?;
    if artifact.remote_system.trim().is_empty()
        || artifact.receipt_kind.trim().is_empty()
        || artifact.evidence_source.trim().is_empty()
        || artifact.observed_at_unix <= 0
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "receipt artifact has empty/invalid required fields",
        )
        .into());
    }
    Ok(())
}

fn record_message_identity(
    db_path: &Path,
    postfix_queue_id: &str,
    message_id: &str,
    observed_at_unix: i64,
) -> Result<MessageIdentityEvidence, AnyError> {
    initialize_schema(db_path)?;
    let mut connection = open_connection(db_path)?;
    let transaction = connection.transaction()?;

    if let Some(existing) = load_message_identity(&transaction, message_id)? {
        if existing.postfix_queue_id != postfix_queue_id {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "Message-ID {message_id} is already mapped to Postfix queue {}, not {postfix_queue_id}",
                    existing.postfix_queue_id
                ),
            )
            .into());
        }
        transaction.commit()?;
        return Ok(existing);
    }

    let observation_ids = {
        let mut statement = transaction.prepare(
            "SELECT observation_id FROM observed_outbound_jobs\n\
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
                "expected exactly one current Postfix observation for queue {postfix_queue_id}, found {}",
                observation_ids.len()
            ),
        )
        .into());
    }
    let observation_id = observation_ids[0].clone();

    transaction.execute(
        "INSERT INTO observed_message_identities(message_id, observation_id, postfix_queue_id, observed_at_unix)\n\
         VALUES (?1, ?2, ?3, ?4)",
        params![message_id, observation_id, postfix_queue_id, observed_at_unix],
    )?;
    transaction.execute(
        "INSERT INTO observed_outbound_events(observation_id, observed_at_unix, event_type, queue_name, delivery_state)\n\
         VALUES (?1, ?2, 'message_id_correlated', NULL, NULL)",
        params![observation_id, observed_at_unix],
    )?;
    transaction.commit()?;

    Ok(MessageIdentityEvidence {
        message_id: message_id.to_string(),
        observation_id,
        postfix_queue_id: postfix_queue_id.to_string(),
        observed_at_unix,
    })
}

fn record_returned_receipt(
    db_path: &Path,
    artifact: &ReturnedReceiptArtifact,
    artifact_json: &str,
    trust_state: &str,
    observed_at_unix: i64,
) -> Result<ReturnedReceiptEvidence, AnyError> {
    initialize_schema(db_path)?;
    let mut connection = open_connection(db_path)?;
    let transaction = connection.transaction()?;

    let identity = load_message_identity(&transaction, &artifact.message_id)?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("no local message identity for {}", artifact.message_id),
        )
    })?;

    let jobs = {
        let mut statement = transaction.prepare(
            "SELECT uucp_job_id FROM observed_uucp_jobs\n\
             WHERE observation_id = ?1 AND remote_system = ?2\n\
             ORDER BY observed_at_unix, uucp_job_id",
        )?;
        let rows = statement
            .query_map(
                params![identity.observation_id, artifact.remote_system],
                |row| row.get::<_, String>(0),
            )?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    if jobs.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "expected exactly one mapped Taylor job for observation {} and remote {}, found {}",
                identity.observation_id,
                artifact.remote_system,
                jobs.len()
            ),
        )
        .into());
    }
    let uucp_job_id = jobs[0].clone();

    if let Some(existing) = load_returned_receipt(
        &transaction,
        &artifact.message_id,
        &artifact.remote_system,
        &artifact.receipt_kind,
        &artifact.evidence_source,
        trust_state,
    )? {
        if existing.artifact_json != artifact_json.trim_end() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "returned receipt was re-observed with conflicting artifact content",
            )
            .into());
        }
        transaction.commit()?;
        return Ok(existing);
    }

    let normalized_json = artifact_json.trim_end().to_string();
    transaction.execute(
        "INSERT INTO observed_returned_receipts(\n\
             message_id, observation_id, postfix_queue_id, remote_system, uucp_job_id,\n\
             receipt_kind, evidence_source, trust_state, artifact_json, observed_at_unix\n\
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            artifact.message_id,
            identity.observation_id,
            identity.postfix_queue_id,
            artifact.remote_system,
            uucp_job_id,
            artifact.receipt_kind,
            artifact.evidence_source,
            trust_state,
            normalized_json,
            observed_at_unix,
        ],
    )?;
    transaction.execute(
        "INSERT INTO observed_outbound_events(observation_id, observed_at_unix, event_type, queue_name, delivery_state)\n\
         VALUES (?1, ?2, 'returned_remote_receipt_observed', NULL, 'returned_receipt_lab_unverified')",
        params![identity.observation_id, observed_at_unix],
    )?;
    transaction.commit()?;

    Ok(ReturnedReceiptEvidence {
        observation_id: identity.observation_id,
        postfix_queue_id: identity.postfix_queue_id,
        remote_system: artifact.remote_system.clone(),
        uucp_job_id,
        message_id: artifact.message_id.clone(),
        receipt_kind: artifact.receipt_kind.clone(),
        evidence_source: artifact.evidence_source.clone(),
        trust_state: trust_state.to_string(),
        artifact_json: normalized_json,
        observed_at_unix,
        evidence_type: "returned_remote_receipt_observed",
    })
}

fn initialize_schema(db_path: &Path) -> Result<(), AnyError> {
    let connection = open_connection(db_path)?;
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS observed_message_identities (\n\
             message_id TEXT PRIMARY KEY NOT NULL,\n\
             observation_id TEXT NOT NULL UNIQUE,\n\
             postfix_queue_id TEXT NOT NULL,\n\
             observed_at_unix INTEGER NOT NULL,\n\
             FOREIGN KEY(observation_id) REFERENCES observed_outbound_jobs(observation_id)\n\
         );\n\
         CREATE TABLE IF NOT EXISTS observed_returned_receipts (\n\
             message_id TEXT NOT NULL,\n\
             observation_id TEXT NOT NULL,\n\
             postfix_queue_id TEXT NOT NULL,\n\
             remote_system TEXT NOT NULL,\n\
             uucp_job_id TEXT NOT NULL,\n\
             receipt_kind TEXT NOT NULL,\n\
             evidence_source TEXT NOT NULL,\n\
             trust_state TEXT NOT NULL,\n\
             artifact_json TEXT NOT NULL,\n\
             observed_at_unix INTEGER NOT NULL,\n\
             PRIMARY KEY(message_id, remote_system, receipt_kind, evidence_source, trust_state),\n\
             FOREIGN KEY(message_id) REFERENCES observed_message_identities(message_id),\n\
             FOREIGN KEY(observation_id) REFERENCES observed_outbound_jobs(observation_id),\n\
             FOREIGN KEY(remote_system, uucp_job_id) REFERENCES observed_uucp_jobs(remote_system, uucp_job_id)\n\
         );\n\
         CREATE INDEX IF NOT EXISTS observed_returned_receipts_observation_idx\n\
             ON observed_returned_receipts(observation_id, observed_at_unix);",
    )?;
    Ok(())
}

fn open_connection(db_path: &Path) -> Result<Connection, AnyError> {
    let connection = Connection::open(db_path)?;
    connection.busy_timeout(std::time::Duration::from_secs(5))?;
    connection.execute_batch("PRAGMA foreign_keys=ON;")?;
    Ok(connection)
}

fn load_message_identity(
    connection: &Connection,
    message_id: &str,
) -> Result<Option<MessageIdentityEvidence>, AnyError> {
    connection
        .query_row(
            "SELECT message_id, observation_id, postfix_queue_id, observed_at_unix\n\
             FROM observed_message_identities WHERE message_id = ?1",
            params![message_id],
            |row| {
                Ok(MessageIdentityEvidence {
                    message_id: row.get(0)?,
                    observation_id: row.get(1)?,
                    postfix_queue_id: row.get(2)?,
                    observed_at_unix: row.get(3)?,
                })
            },
        )
        .optional()
        .map_err(Into::into)
}

fn load_returned_receipt(
    connection: &Connection,
    message_id: &str,
    remote_system: &str,
    receipt_kind: &str,
    evidence_source: &str,
    trust_state: &str,
) -> Result<Option<ReturnedReceiptEvidence>, AnyError> {
    connection
        .query_row(
            "SELECT observation_id, postfix_queue_id, remote_system, uucp_job_id, message_id,\n\
                    receipt_kind, evidence_source, trust_state, artifact_json, observed_at_unix\n\
             FROM observed_returned_receipts\n\
             WHERE message_id = ?1 AND remote_system = ?2 AND receipt_kind = ?3\n\
               AND evidence_source = ?4 AND trust_state = ?5",
            params![
                message_id,
                remote_system,
                receipt_kind,
                evidence_source,
                trust_state
            ],
            |row| {
                Ok(ReturnedReceiptEvidence {
                    observation_id: row.get(0)?,
                    postfix_queue_id: row.get(1)?,
                    remote_system: row.get(2)?,
                    uucp_job_id: row.get(3)?,
                    message_id: row.get(4)?,
                    receipt_kind: row.get(5)?,
                    evidence_source: row.get(6)?,
                    trust_state: row.get(7)?,
                    artifact_json: row.get(8)?,
                    observed_at_unix: row.get(9)?,
                    evidence_type: "returned_remote_receipt_observed",
                })
            },
        )
        .optional()
        .map_err(Into::into)
}

fn load_message_identities(
    connection: &Connection,
) -> Result<Vec<MessageIdentityEvidence>, AnyError> {
    let mut statement = connection.prepare(
        "SELECT message_id, observation_id, postfix_queue_id, observed_at_unix\n\
         FROM observed_message_identities ORDER BY observed_at_unix, message_id",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok(MessageIdentityEvidence {
                message_id: row.get(0)?,
                observation_id: row.get(1)?,
                postfix_queue_id: row.get(2)?,
                observed_at_unix: row.get(3)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

fn load_returned_receipts(
    connection: &Connection,
) -> Result<Vec<ReturnedReceiptEvidence>, AnyError> {
    let mut statement = connection.prepare(
        "SELECT observation_id, postfix_queue_id, remote_system, uucp_job_id, message_id,\n\
                receipt_kind, evidence_source, trust_state, artifact_json, observed_at_unix\n\
         FROM observed_returned_receipts ORDER BY observed_at_unix, message_id",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok(ReturnedReceiptEvidence {
                observation_id: row.get(0)?,
                postfix_queue_id: row.get(1)?,
                remote_system: row.get(2)?,
                uucp_job_id: row.get(3)?,
                message_id: row.get(4)?,
                receipt_kind: row.get(5)?,
                evidence_source: row.get(6)?,
                trust_state: row.get(7)?,
                artifact_json: row.get(8)?,
                observed_at_unix: row.get(9)?,
                evidence_type: "returned_remote_receipt_observed",
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
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

fn usage_error() -> AnyError {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "usage: oceanmail-returned-receipt-evidence message-record [--state-db PATH] --postfix-queue-id ID --message-id ID | returned-record [--state-db PATH] --artifact PATH --trust-state STATE | list [--state-db PATH]",
    )
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phase4i_trust_state_is_fail_closed() {
        assert!(validate_trust_state(LAB_RECEIPT_TRUST_STATE).is_ok());
        assert!(validate_trust_state("").is_err());
        assert!(validate_trust_state("verified").is_err());
        assert!(validate_trust_state("cryptographically_verified").is_err());
        assert!(validate_trust_state("lab_peer_transport_verified").is_err());
        assert!(validate_trust_state(" lab_peer_transport_unverified").is_err());
    }
}
