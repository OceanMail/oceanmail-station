use axum::{extract::Extension, routing::get, Json};
use oceanmail_station::auth::{build_auth_router, LabAuth};
use oceanmail_station::{
    build_router, default_state_db_path, default_station_name, initialize_station, now_unix,
    parse_loopback_bind, parse_postqueue_json_lines, reconcile_outbound_snapshot, AnyError,
    AppState,
};
use serde::Serialize;
use std::{env, io, path::PathBuf, sync::Arc};
use tokio::{
    net::TcpListener,
    process::Command,
    signal,
    sync::RwLock,
    time::{interval, Duration, MissedTickBehavior},
};

#[derive(Debug, Serialize)]
struct StorageSecurityStatus {
    production_storage_ready: bool,
    application_storage_encryption: bool,
    per_user_key_separation: bool,
    host_volume_encryption_verified: bool,
    note: &'static str,
}

#[derive(Clone, Debug, Serialize)]
struct QueueObserverStatus {
    mode: &'static str,
    poll_interval_seconds: u64,
    last_attempt_at_unix: Option<i64>,
    last_success_at_unix: Option<i64>,
    last_observed_entry_count: Option<usize>,
    consecutive_failures: u64,
    last_error: Option<String>,
}

impl QueueObserverStatus {
    fn new(poll_interval_seconds: u64) -> Self {
        Self {
            mode: "autonomous_postfix_polling",
            poll_interval_seconds,
            last_attempt_at_unix: None,
            last_success_at_unix: None,
            last_observed_entry_count: None,
            consecutive_failures: 0,
            last_error: None,
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), AnyError> {
    let bind_value = env::var("OCEANMAIL_BIND").unwrap_or_else(|_| "127.0.0.1:8080".to_string());
    let bind = parse_loopback_bind(&bind_value)?;

    let db_path = default_state_db_path();
    let station_name = default_station_name();
    let station = initialize_station(&db_path, &station_name)?;
    // Only runtime-provisioned laboratory credentials; never stored in Station SQLite.
    // parse_loopback_bind above remains mandatory even when auth is configured.
    let auth = LabAuth::from_runtime_file(
        station.station_id.clone(),
        env::var_os("OCEANMAIL_LAB_AUTH_FILE")
            .map(PathBuf::from)
            .as_deref(),
    )?;

    let postqueue_path = env::var("OCEANMAIL_POSTQUEUE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/usr/sbin/postqueue"));
    let poll_interval_seconds = queue_poll_interval_seconds();

    let state = AppState {
        station: station.clone(),
        postqueue_path: postqueue_path.clone(),
        state_db_path: db_path.clone(),
    };
    let observer_status = Arc::new(RwLock::new(QueueObserverStatus::new(poll_interval_seconds)));

    tokio::spawn(queue_observer_loop(
        state.clone(),
        observer_status.clone(),
        poll_interval_seconds,
    ));

    let app = build_router(state)
        .merge(build_auth_router(auth))
        .route("/api/v1/security/storage", get(storage_security))
        .route(
            "/api/v1/queues/outbound/observer",
            get(queue_observer_status),
        )
        .layer(Extension(observer_status));

    let listener = TcpListener::bind(bind).await?;
    eprintln!(
        "oceanmail-station {} listening on http://{} station_id={} state_db={} postqueue={} queue_poll_seconds={} production_storage_ready=false application_storage_encryption=false per_user_key_separation=false",
        env!("CARGO_PKG_VERSION"),
        bind,
        station.station_id,
        db_path.display(),
        postqueue_path.display(),
        poll_interval_seconds,
    );

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
}

fn queue_poll_interval_seconds() -> u64 {
    env::var("OCEANMAIL_QUEUE_POLL_SECONDS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(5)
}

async fn queue_observer_loop(
    state: AppState,
    status: Arc<RwLock<QueueObserverStatus>>,
    poll_interval_seconds: u64,
) {
    let mut ticker = interval(Duration::from_secs(poll_interval_seconds));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);

    loop {
        ticker.tick().await;
        let attempted_at = now_unix();
        {
            let mut current = status.write().await;
            current.last_attempt_at_unix = Some(attempted_at);
        }

        match observe_postfix_once(&state).await {
            Ok((observed_at, entry_count)) => {
                let mut current = status.write().await;
                current.last_success_at_unix = Some(observed_at);
                current.last_observed_entry_count = Some(entry_count);
                current.consecutive_failures = 0;
                current.last_error = None;
            }
            Err(err) => {
                let message = err.to_string();
                eprintln!("queue observer poll failed: {message}");
                let mut current = status.write().await;
                current.consecutive_failures = current.consecutive_failures.saturating_add(1);
                current.last_error = Some(message);
            }
        }
    }
}

async fn observe_postfix_once(state: &AppState) -> Result<(i64, usize), AnyError> {
    let output = Command::new(&state.postqueue_path)
        .arg("-j")
        .output()
        .await?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!(
                "{} -j exited with {}{}",
                state.postqueue_path.display(),
                output.status,
                if stderr.is_empty() {
                    String::new()
                } else {
                    format!(": {stderr}")
                }
            ),
        )
        .into());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let entries = parse_postqueue_json_lines(&stdout, &state.station.station_id)
        .map_err(|message| io::Error::new(io::ErrorKind::InvalidData, message))?;
    let observed_at = now_unix();
    reconcile_outbound_snapshot(&state.state_db_path, &entries, observed_at)?;

    Ok((observed_at, entries.len()))
}

async fn queue_observer_status(
    Extension(status): Extension<Arc<RwLock<QueueObserverStatus>>>,
) -> Json<QueueObserverStatus> {
    Json(status.read().await.clone())
}

async fn storage_security() -> Json<StorageSecurityStatus> {
    Json(StorageSecurityStatus {
        production_storage_ready: false,
        application_storage_encryption: false,
        per_user_key_separation: false,
        host_volume_encryption_verified: false,
        note: "Phase 4 uses laboratory plaintext SQLite state. Production Station storage requires encryption at rest and per-user key separation for private data.",
    })
}

async fn shutdown_signal() {
    let _ = signal::ctrl_c().await;
}
