//! Phase 4J laboratory client authentication. Not a production identity provider.
//! Credentials are operator-provisioned at runtime and never persisted by Station.
use axum::{
    extract::{Path as ApiPath, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs::File,
    io::{self, Read},
    path::Path,
    sync::Arc,
};
use subtle::ConstantTimeEq;

const MAX_CONFIG_BYTES: u64 = 64 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    OwnerCaptain,
    Admin,
    Operator,
    User,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum StationPermission {
    AuthContextRead,
    StationStatusRead,
    StationAdmin,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum AccountPermission {
    ContextRead,
    AvailableRead,
    RetrievalPlanRead,
    RetrievalPlanWrite,
    AccountingRead,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct AccountGrant {
    account_id: String,
    permissions: Vec<AccountPermission>,
}

/// Immutable, server-derived context. No client header/body can assert these fields.
#[derive(Clone, Debug, Serialize)]
pub struct RequestContext {
    station_id: String,
    user_id: String,
    role: Role,
    permissions: Vec<StationPermission>,
    device_id: String,
    device_trusted: bool,
    account_grants: Vec<AccountGrant>,
    expires_at_unix: i64,
    authentication: &'static str,
}

impl RequestContext {
    pub fn require_station(&self, permission: StationPermission) -> Result<(), AuthError> {
        if self.permissions.contains(&permission) {
            Ok(())
        } else {
            Err(AuthError::Forbidden)
        }
    }

    /// Check BEFORE looking up private resources. Role/device trust confer no grant.
    pub fn require_account(
        &self,
        account_id: &str,
        permission: AccountPermission,
    ) -> Result<(), AuthError> {
        if self
            .account_grants
            .iter()
            .any(|grant| grant.account_id == account_id && grant.permissions.contains(&permission))
        {
            Ok(())
        } else {
            Err(AuthError::Forbidden)
        }
    }
}

// Intentionally no Debug/Serialize on configuration or credential-bearing types.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    laboratory_only: bool,
    credentials: Vec<CredentialConfig>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CredentialConfig {
    token: String,
    user_id: String,
    role: Role,
    permissions: Vec<StationPermission>,
    device_id: String,
    device_trusted: bool,
    account_grants: Vec<AccountGrant>,
    expires_at_unix: i64,
}

struct Credential {
    token: [u8; 32],
    context: RequestContext,
}

#[derive(Clone)]
pub struct LabAuth {
    credentials: Arc<Vec<Credential>>,
}

fn invalid_config() -> io::Error {
    // Never include serde errors, input values, credential paths or secrets.
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "invalid laboratory authentication configuration",
    )
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_-.:".contains(&c))
}

fn token_bytes(value: &str) -> Option<[u8; 32]> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        return None;
    }
    let mut bytes = [0; 32];
    for (index, byte) in bytes.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&value[index * 2..index * 2 + 2], 16).ok()?;
    }
    Some(bytes)
}

fn unique<T: Eq + std::hash::Hash>(values: &[T]) -> bool {
    values.iter().collect::<HashSet<_>>().len() == values.len()
}

#[cfg(unix)]
fn trusted_runtime_file(owner: u32, effective_user: u32, mode: u32) -> bool {
    owner == effective_user && mode & 0o077 == 0
}

impl LabAuth {
    pub fn from_runtime_file(station_id: String, path: Option<&Path>) -> io::Result<Self> {
        let Some(path) = path else {
            return Ok(Self {
                credentials: Arc::new(Vec::new()),
            });
        };
        // Runtime file must be an operator-controlled regular, owner-only file.
        let file = File::open(path).map_err(|_| invalid_config())?;
        let metadata = file.metadata().map_err(|_| invalid_config())?;
        if !metadata.is_file() || metadata.len() > MAX_CONFIG_BYTES {
            return Err(invalid_config());
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::{MetadataExt, PermissionsExt};
            // SAFETY: geteuid has no pointer arguments or preconditions and only
            // reads this process's effective UID. Check the opened descriptor,
            // not a path lookup that could race a file replacement.
            let effective_user = unsafe { libc::geteuid() };
            if !trusted_runtime_file(
                metadata.uid(),
                effective_user,
                metadata.permissions().mode(),
            ) {
                return Err(invalid_config());
            }
        }
        #[cfg(not(unix))]
        return Err(invalid_config());
        let mut content = String::new();
        file.take(MAX_CONFIG_BYTES + 1)
            .read_to_string(&mut content)
            .map_err(|_| invalid_config())?;
        Self::from_json(station_id, &content)
    }

    fn from_json(station_id: String, content: &str) -> io::Result<Self> {
        if content.len() > MAX_CONFIG_BYTES as usize || !valid_id(&station_id) {
            return Err(invalid_config());
        }
        let config: Config = serde_json::from_str(content).map_err(|_| invalid_config())?;
        if !config.laboratory_only || config.credentials.len() > 128 {
            return Err(invalid_config());
        }
        let mut credentials: Vec<Credential> = Vec::new();
        for entry in config.credentials {
            let token = token_bytes(&entry.token).ok_or_else(invalid_config)?;
            let account_ids: Vec<_> = entry.account_grants.iter().map(|g| &g.account_id).collect();
            if !valid_id(&entry.user_id)
                || !valid_id(&entry.device_id)
                || entry.expires_at_unix <= 0
                || !unique(&entry.permissions)
                || !unique(&account_ids)
                || entry
                    .account_grants
                    .iter()
                    .any(|g| !valid_id(&g.account_id) || !unique(&g.permissions))
                || credentials
                    .iter()
                    .any(|c| bool::from(c.token.ct_eq(&token)))
            {
                return Err(invalid_config());
            }
            credentials.push(Credential {
                token,
                context: RequestContext {
                    station_id: station_id.clone(),
                    user_id: entry.user_id,
                    role: entry.role,
                    permissions: entry.permissions,
                    device_id: entry.device_id,
                    device_trusted: entry.device_trusted,
                    account_grants: entry.account_grants,
                    expires_at_unix: entry.expires_at_unix,
                    authentication: "laboratory_runtime_bearer",
                },
            });
        }
        Ok(Self {
            credentials: Arc::new(credentials),
        })
    }

    pub fn authenticate(&self, headers: &HeaderMap, now: i64) -> Result<RequestContext, AuthError> {
        let mut values = headers.get_all(header::AUTHORIZATION).iter();
        let value = values.next().ok_or(AuthError::Unauthorized)?;
        if values.next().is_some() {
            return Err(AuthError::Unauthorized);
        }
        let value = value.to_str().map_err(|_| AuthError::Unauthorized)?;
        let (scheme, token) = value.split_once(' ').ok_or(AuthError::Unauthorized)?;
        if !scheme.eq_ignore_ascii_case("Bearer") {
            return Err(AuthError::Unauthorized);
        }
        let token = token_bytes(token).ok_or(AuthError::Unauthorized)?;
        let mut matched = None;
        // Fixed-length constant-time token comparison; scan all configured entries.
        for credential in self.credentials.iter() {
            if bool::from(credential.token.ct_eq(&token))
                && now < credential.context.expires_at_unix
            {
                matched = Some(credential.context.clone());
            }
        }
        matched.ok_or(AuthError::Unauthorized)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum AuthError {
    Unauthorized,
    Forbidden,
}

fn private_response(value: impl Serialize, status: StatusCode) -> Response {
    let mut response = (status, Json(value)).into_response();
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
        .headers_mut()
        .insert(header::VARY, HeaderValue::from_static("Authorization"));
    response
}

impl IntoResponse for AuthError {
    fn into_response(self) -> Response {
        let (status, code) = match self {
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            Self::Forbidden => (StatusCode::FORBIDDEN, "forbidden"),
        };
        let mut response = private_response(serde_json::json!({"error": code}), status);
        if status == StatusCode::UNAUTHORIZED {
            response
                .headers_mut()
                .insert(header::WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
        }
        response
    }
}

pub fn build_auth_router(auth: LabAuth) -> Router {
    Router::new()
        .route("/api/v1/auth/context", get(context))
        .route(
            "/api/v1/accounts/{account_id}/auth/context",
            get(account_context),
        )
        .with_state(auth)
}

async fn context(State(auth): State<LabAuth>, headers: HeaderMap) -> Result<Response, AuthError> {
    let context = auth.authenticate(&headers, crate::now_unix())?;
    context.require_station(StationPermission::AuthContextRead)?;
    Ok(private_response(context, StatusCode::OK))
}

async fn account_context(
    State(auth): State<LabAuth>,
    ApiPath(account_id): ApiPath<String>,
    headers: HeaderMap,
) -> Result<Response, AuthError> {
    let mut context = auth.authenticate(&headers, crate::now_unix())?;
    context.require_account(&account_id, AccountPermission::ContextRead)?;
    // Return only the requested account scope, never neighboring account grants.
    context
        .account_grants
        .retain(|grant| grant.account_id == account_id);
    Ok(private_response(context, StatusCode::OK))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(unix)]
    fn runtime_file_requires_effective_user_ownership_even_for_root() {
        assert!(trusted_runtime_file(1000, 1000, 0o600));
        assert!(trusted_runtime_file(0, 0, 0o400));
        assert!(!trusted_runtime_file(1000, 0, 0o600));
        assert!(!trusted_runtime_file(0, 1000, 0o600));
        assert!(!trusted_runtime_file(1001, 1000, 0o600));
        assert!(!trusted_runtime_file(1000, 1000, 0o640));
        assert!(!trusted_runtime_file(1000, 1000, 0o604));
    }
    fn config() -> serde_json::Value {
        serde_json::json!({"laboratory_only": true, "credentials": [{
            "token": "a".repeat(64), "user_id": "user-a", "role": "user",
            "permissions": ["auth_context_read"], "device_id": "device-a", "device_trusted": false,
            "account_grants": [{"account_id": "account-a", "permissions": ["context_read", "available_read"]}],
            "expires_at_unix": 1000
        }]})
    }
    fn auth(config: &serde_json::Value) -> LabAuth {
        LabAuth::from_json("station-a".into(), &config.to_string()).unwrap()
    }
    fn headers(token: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            format!("Bearer {token}").parse().unwrap(),
        );
        headers
    }

    #[test]
    fn missing_invalid_ambiguous_and_expired_credentials_fail_closed() {
        let auth = auth(&config());
        assert!(matches!(
            auth.authenticate(&HeaderMap::new(), 1),
            Err(AuthError::Unauthorized)
        ));
        for token in [
            "b".repeat(64),
            "a".repeat(63),
            "a".repeat(65),
            "a".repeat(64) + ",other",
        ] {
            assert!(matches!(
                auth.authenticate(&headers(&token), 1),
                Err(AuthError::Unauthorized)
            ));
        }
        let mut h = headers(&"a".repeat(64));
        assert!(auth.authenticate(&h, 999).is_ok());
        assert!(matches!(
            auth.authenticate(&h, 1000),
            Err(AuthError::Unauthorized)
        ));
        h.append(header::AUTHORIZATION, h[header::AUTHORIZATION].clone());
        assert!(matches!(
            auth.authenticate(&h, 1),
            Err(AuthError::Unauthorized)
        ));
    }

    #[test]
    fn role_and_device_trust_never_confer_account_or_station_permissions() {
        for role in ["owner_captain", "admin", "operator", "user"] {
            for trusted in [true, false] {
                let mut c = config();
                c["credentials"][0]["role"] = role.into();
                c["credentials"][0]["device_trusted"] = trusted.into();
                let context = auth(&c).authenticate(&headers(&"a".repeat(64)), 1).unwrap();
                assert_eq!(context.device_trusted, trusted);
                assert_eq!(
                    context.require_account("account-a", AccountPermission::AvailableRead),
                    Ok(())
                );
                assert_eq!(
                    context.require_account("account-b", AccountPermission::AvailableRead),
                    Err(AuthError::Forbidden)
                );
                assert_eq!(
                    context.require_account("account-a", AccountPermission::RetrievalPlanWrite),
                    Err(AuthError::Forbidden)
                );
                assert_eq!(
                    context.require_station(StationPermission::StationAdmin),
                    Err(AuthError::Forbidden)
                );
            }
        }
    }

    #[test]
    fn explicit_permissions_not_role_determine_access() {
        let mut c = config();
        c["credentials"][0]["permissions"] = serde_json::json!(["station_admin"]);
        c["credentials"][0]["account_grants"] = serde_json::json!([]);
        let context = auth(&c).authenticate(&headers(&"a".repeat(64)), 1).unwrap();
        assert_eq!(
            context.require_station(StationPermission::StationAdmin),
            Ok(())
        );
        assert_eq!(
            context.require_station(StationPermission::AuthContextRead),
            Err(AuthError::Forbidden)
        );
        assert_eq!(
            context.require_account("account-a", AccountPermission::ContextRead),
            Err(AuthError::Forbidden)
        );
    }

    #[test]
    fn invalid_configuration_is_rejected_without_echoing_secrets() {
        let baseline = config();
        let mut cases = Vec::new();
        let mut c = baseline.clone();
        c["laboratory_only"] = false.into();
        cases.push(c);
        let mut c = baseline.clone();
        c["credentials"][0]["permissions"] = serde_json::json!(["all"]);
        cases.push(c);
        let mut c = baseline.clone();
        c["credentials"][0]["unknown_secret"] = "private".into();
        cases.push(c);
        let mut c = baseline.clone();
        c["credentials"][0]["user_id"] = "".into();
        cases.push(c);
        let mut c = baseline.clone();
        c["credentials"]
            .as_array_mut()
            .unwrap()
            .push(baseline["credentials"][0].clone());
        cases.push(c);
        let mut c = baseline.clone();
        c["credentials"][0]["account_grants"]
            .as_array_mut()
            .unwrap()
            .push(baseline["credentials"][0]["account_grants"][0].clone());
        cases.push(c);
        for case in cases {
            let err = LabAuth::from_json("station-a".into(), &case.to_string())
                .err()
                .unwrap();
            assert_eq!(
                err.to_string(),
                "invalid laboratory authentication configuration"
            );
        }
    }

    #[test]
    fn context_is_stable_on_reprovision_and_contains_no_secret() {
        let c = config();
        let first = auth(&c).authenticate(&headers(&"a".repeat(64)), 1).unwrap();
        let second = auth(&c).authenticate(&headers(&"a".repeat(64)), 1).unwrap();
        let first = serde_json::to_string(&first).unwrap();
        assert_eq!(first, serde_json::to_string(&second).unwrap());
        assert!(!first.contains(&"a".repeat(64)));
        assert!(!first.contains("token"));
    }
}
