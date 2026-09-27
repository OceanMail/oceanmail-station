use oceanmail_station::{default_state_db_path, now_unix, AnyError};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use std::{
    env, io,
    path::{Path, PathBuf},
};

// This tool has no way to itself re-verify that the far-side mailbox was
// actually inspected: that verification happens in the caller (see
// scripts/phase4h-remote-mailbox-receipt.sh's real `python3 -c "import
// mailbox; ..."` check before it ever invokes `record`). Restricting
// `--receipt-kind` to exactly the claims this tool's callers are known to
// have verified prevents an unreviewed future caller from writing the
// strong `remote_mailbox_receipt_observed` durable evidence claim (AGENTS.md:
// "exact far-side mailbox evidence, not human-read status") for a receipt
// kind nothing has actually checked. Mirrors validate_trust_state's
// fail-closed allow-list in oceanmail-returned-receipt-evidence.rs.
const RECOGNIZED_RECEIPT_KIND: &str = "mailbox_message_present";

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
struct RemoteReceiptEvidence {
    observation_id: String,
    postfix_queue_id: String,
    remote_system: String,
    uucp_job_id: String,
    message_id: String,
    receipt_kind: String,
    evidence_source: String,
    observed_at_unix: i64,
    evidence_type: &'static str,
}

#[derive(Debug, Serialize)]
struct RemoteReceiptList {
    source: &'static str,
    receipts: Vec<RemoteReceiptEvidence>,
}

fn main() -> Result<(), AnyError> {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("record") => record_command(&args[1..]),
        Some("list") => list_command(&args[1..]),
        _ => Err(usage_error()),
    }
}

fn record_command(args: &[String]) -> Result<(), AnyError> {
    let db_path = state_db_from_args(args)?;
    let remote_system = required_flag(args, "--remote-system")?;
    let uucp_job_id = required_flag(args, "--uucp-job-id")?;
    let message_id = required_flag(args, "--message-id")?;
    let receipt_kind = required_flag(args, "--receipt-kind")?;
    let evidence_source = required_flag(args, "--source")?;

    if message_id.trim().is_empty()
        || receipt_kind.trim().is_empty()
        || evidence_source.trim().is_empty()
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "message-id, receipt-kind, and source must be non-empty",
        )
        .into());
    }
    validate_receipt_kind(&receipt_kind)?;

    let receipt = record_receipt(
        &db_path,
        &remote_system,
        &uucp_job_id,
        &message_id,
        &receipt_kind,
        &evidence_source,
        now_unix(),
    )?;
    println!("{}", serde_json::to_string(&receipt)?);
    Ok(())
}

fn list_command(args: &[String]) -> Result<(), AnyError> {
    let db_path = state_db_from_args(args)?;
    initialize_schema(&db_path)?;
    let connection = open_connection(&db_path)?;
    let receipts = load_receipts(&connection)?;
    println!(
        "{}",
        serde_json::to_string(&RemoteReceiptList {
            source: "station-sqlite-remote-receipt-evidence",
            receipts,
        })?
    );
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

fn usage_error() -> AnyError {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "usage: oceanmail-remote-receipt-evidence record [--state-db PATH] --remote-system SYSTEM --uucp-job-id ID --message-id ID --receipt-kind KIND --source SOURCE | oceanmail-remote-receipt-evidence list [--state-db PATH]",
    )
    .into()
}

fn validate_receipt_kind(receipt_kind: &str) -> Result<(), AnyError> {
    if receipt_kind != RECOGNIZED_RECEIPT_KIND {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "unsupported receipt-kind {receipt_kind:?}; this tool only accepts {RECOGNIZED_RECEIPT_KIND:?} \
                 because that is the only claim its current callers actually verify before recording it \
                 (see scripts/phase4h-remote-mailbox-receipt.sh)"
            ),
        )
        .into());
    }
    Ok(())
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
        "CREATE TABLE IF NOT EXISTS observed_remote_receipts (\n\
             observation_id TEXT NOT NULL,\n\
             postfix_queue_id TEXT NOT NULL,\n\
             remote_system TEXT NOT NULL,\n\
             uucp_job_id TEXT NOT NULL,\n\
             message_id TEXT NOT NULL,\n\
             receipt_kind TEXT NOT NULL,\n\
             evidence_source TEXT NOT NULL,\n\
             observed_at_unix INTEGER NOT NULL,\n\
             PRIMARY KEY(remote_system, uucp_job_id, message_id, receipt_kind, evidence_source),\n\
             FOREIGN KEY(observation_id) REFERENCES observed_outbound_jobs(observation_id),\n\
             FOREIGN KEY(remote_system, uucp_job_id) REFERENCES observed_uucp_jobs(remote_system, uucp_job_id)\n\
         );\n\
         CREATE INDEX IF NOT EXISTS observed_remote_receipts_observation_idx\n\
             ON observed_remote_receipts(observation_id, observed_at_unix);",
    )?;
    Ok(())
}

fn record_receipt(
    db_path: &Path,
    remote_system: &str,
    uucp_job_id: &str,
    message_id: &str,
    receipt_kind: &str,
    evidence_source: &str,
    observed_at_unix: i64,
) -> Result<RemoteReceiptEvidence, AnyError> {
    initialize_schema(db_path)?;
    let mut connection = open_connection(db_path)?;
    let transaction = connection.transaction()?;

    if let Some(existing) = load_receipt(
        &transaction,
        remote_system,
        uucp_job_id,
        message_id,
        receipt_kind,
        evidence_source,
    )? {
        transaction.commit()?;
        return Ok(existing);
    }

    let mapping: Option<(String, String)> = transaction
        .query_row(
            "SELECT observation_id, postfix_queue_id\n\
             FROM observed_uucp_jobs\n\
             WHERE remote_system = ?1 AND uucp_job_id = ?2",
            params![remote_system, uucp_job_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((observation_id, postfix_queue_id)) = mapping else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("no mapped UUCP job {remote_system}/{uucp_job_id}"),
        )
        .into());
    };

    transaction.execute(
        "INSERT INTO observed_remote_receipts(\n\
             observation_id, postfix_queue_id, remote_system, uucp_job_id,\n\
             message_id, receipt_kind, evidence_source, observed_at_unix\n\
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            observation_id,
            postfix_queue_id,
            remote_system,
            uucp_job_id,
            message_id,
            receipt_kind,
            evidence_source,
            observed_at_unix,
        ],
    )?;

    transaction.execute(
        "INSERT INTO observed_outbound_events(\n\
             observation_id, observed_at_unix, event_type, queue_name, delivery_state\n\
         ) VALUES (?1, ?2, 'remote_mailbox_receipt_observed', NULL, 'remote_mailbox_observed')",
        params![observation_id, observed_at_unix],
    )?;

    transaction.commit()?;

    Ok(RemoteReceiptEvidence {
        observation_id,
        postfix_queue_id,
        remote_system: remote_system.to_string(),
        uucp_job_id: uucp_job_id.to_string(),
        message_id: message_id.to_string(),
        receipt_kind: receipt_kind.to_string(),
        evidence_source: evidence_source.to_string(),
        observed_at_unix,
        evidence_type: "remote_mailbox_receipt_observed",
    })
}

fn load_receipt(
    connection: &Connection,
    remote_system: &str,
    uucp_job_id: &str,
    message_id: &str,
    receipt_kind: &str,
    evidence_source: &str,
) -> Result<Option<RemoteReceiptEvidence>, AnyError> {
    connection
        .query_row(
            "SELECT observation_id, postfix_queue_id, remote_system, uucp_job_id,\n\
                    message_id, receipt_kind, evidence_source, observed_at_unix\n\
             FROM observed_remote_receipts\n\
             WHERE remote_system = ?1 AND uucp_job_id = ?2 AND message_id = ?3\n\
               AND receipt_kind = ?4 AND evidence_source = ?5",
            params![
                remote_system,
                uucp_job_id,
                message_id,
                receipt_kind,
                evidence_source,
            ],
            |row| {
                Ok(RemoteReceiptEvidence {
                    observation_id: row.get(0)?,
                    postfix_queue_id: row.get(1)?,
                    remote_system: row.get(2)?,
                    uucp_job_id: row.get(3)?,
                    message_id: row.get(4)?,
                    receipt_kind: row.get(5)?,
                    evidence_source: row.get(6)?,
                    observed_at_unix: row.get(7)?,
                    evidence_type: "remote_mailbox_receipt_observed",
                })
            },
        )
        .optional()
        .map_err(Into::into)
}

fn load_receipts(connection: &Connection) -> Result<Vec<RemoteReceiptEvidence>, AnyError> {
    let mut statement = connection.prepare(
        "SELECT observation_id, postfix_queue_id, remote_system, uucp_job_id,\n\
                message_id, receipt_kind, evidence_source, observed_at_unix\n\
         FROM observed_remote_receipts\n\
         ORDER BY observed_at_unix, remote_system, uucp_job_id",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok(RemoteReceiptEvidence {
                observation_id: row.get(0)?,
                postfix_queue_id: row.get(1)?,
                remote_system: row.get(2)?,
                uucp_job_id: row.get(3)?,
                message_id: row.get(4)?,
                receipt_kind: row.get(5)?,
                evidence_source: row.get(6)?,
                observed_at_unix: row.get(7)?,
                evidence_type: "remote_mailbox_receipt_observed",
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn receipt_kind_is_fail_closed_to_the_one_verified_claim() {
        assert!(validate_receipt_kind(RECOGNIZED_RECEIPT_KIND).is_ok());
        assert!(validate_receipt_kind("").is_err());
        assert!(validate_receipt_kind("mailbox_message_verified").is_err());
        assert!(validate_receipt_kind("delivered").is_err());
        assert!(validate_receipt_kind(" mailbox_message_present").is_err());
        assert!(validate_receipt_kind("mailbox_message_present ").is_err());
    }
}
