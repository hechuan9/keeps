use std::{collections::HashMap, sync::Arc};

use crate::{previews::PreviewStorage, store::Store};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, Query, Request, State},
    http::{HeaderMap, Method, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
};
use serde::Deserialize;
use serde_json::{Value, json};
use tower_http::trace::TraceLayer;

pub struct AppState {
    pub store: Arc<Store>,
    pub previews: Arc<PreviewStorage>,
    pub jobs: Arc<crate::jobs::Jobs>,
    pub access_token: String,
    pub library_id: String,
    pub original_root_names: crate::navigation::RootNames,
}

type ApiResult = Result<Response, ApiError>;
pub struct ApiError(StatusCode, String, String);
impl ApiError {
    fn bad(message: impl Into<String>) -> Self {
        Self(
            StatusCode::BAD_REQUEST,
            "invalid_request".into(),
            message.into(),
        )
    }
}
impl From<anyhow::Error> for ApiError {
    fn from(error: anyhow::Error) -> Self {
        tracing::error!(error = ?error, "request failed");
        if let Some(e) = error.downcast_ref::<crate::store::StoreError>() {
            return Self(
                StatusCode::from_u16(e.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
                e.code.clone(),
                e.message.clone(),
            );
        }
        if let Some(e) = error.downcast_ref::<crate::previews::PreviewError>() {
            return Self(
                StatusCode::from_u16(e.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
                e.code.clone(),
                e.message.clone(),
            );
        }
        Self(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error".into(),
            "server operation failed; see server logs".into(),
        )
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.0,
            Json(json!({"detail":{"code":self.1,"message":self.2}})),
        )
            .into_response()
    }
}

pub fn router(state: Arc<AppState>) -> Router {
    let protected = Router::new()
        .merge(crate::remote_worker::router())
        .merge(crate::edits::router())
        .merge(crate::video_trim::router())
        .merge(crate::rejected_trash::router())
        .merge(crate::imports::router())
        .merge(crate::offline_rebuild::router(state.clone()))
        .route("/libraries/{library}/assets", get(assets))
        .route(
            "/libraries/{library}/tags",
            get(tag_library).post(add_tags_to_library),
        )
        .route(
            "/libraries/{library}/assets/{asset}",
            get(asset).patch(patch_asset),
        )
        .route(
            "/libraries/{library}/assets/{asset}/trash",
            post(trash_asset),
        )
        .route(
            "/libraries/{library}/assets/{asset}/restore",
            post(restore_asset),
        )
        .route(
            "/libraries/{library}/assets/{asset}/versions",
            get(versions),
        )
        .route(
            "/libraries/{library}/assets/{asset}/versions/{hash}/download",
            get(version_download),
        )
        .route(
            "/libraries/{library}/assets/{asset}/version-candidates",
            get(version_candidates),
        )
        .route(
            "/libraries/{library}/assets/{asset}/default-version",
            axum::routing::put(default_version),
        )
        .route(
            "/libraries/{library}/assets/{asset}/versions/{hash}/playback",
            get(version_playback),
        )
        .route("/libraries/{library}/revision", get(revision))
        .route("/libraries/{library}/counts", get(counts))
        .route("/libraries/{library}/cache-status", get(cache_status))
        .route("/libraries/{library}/task-status", get(task_status))
        .route("/libraries/{library}/cache-retry", post(cache_retry))
        .route("/libraries/{library}/cache-rebuild", post(cache_rebuild))
        .route(
            "/libraries/{library}/hidden-directories",
            get(hidden_directories).put(set_hidden_directory),
        )
        .route(
            "/libraries/{library}/directories",
            get(directories).post(create_directory),
        )
        .route(
            "/libraries/{library}/directories/refresh",
            post(refresh_directory),
        )
        .route(
            "/libraries/{library}/assets/move-tasks",
            post(submit_asset_move),
        )
        .route(
            "/libraries/{library}/assets/move-tasks/{request_id}",
            get(asset_move_status),
        )
        .route(
            "/libraries/{library}/directories/move-tasks",
            post(submit_directory_move),
        )
        .route(
            "/libraries/{library}/directories/move-tasks/{request_id}",
            get(directory_move_status),
        )
        .route(
            "/libraries/{library}/directories/move",
            post(move_directory),
        )
        .route(
            "/libraries/{library}/directories/trash",
            post(trash_directory),
        )
        .route(
            "/libraries/{library}/directories/trash/{request_id}",
            get(directory_trash_status),
        )
        .route("/libraries/{library}/navigation", get(navigation))
        .route(
            "/libraries/{library}/folders",
            get(folders).post(add_folder),
        )
        .route(
            "/libraries/{library}/folders/{folder}",
            delete(remove_folder),
        )
        .route(
            "/libraries/{library}/folders/{folder}/scan",
            post(scan_folder),
        )
        .route("/libraries/{library}/jobs", get(jobs))
        .route("/libraries/{library}/jobs/{job}/retry", post(retry_job))
        .route("/derivatives/{asset}", get(derivative_metadata))
        .route_layer(middleware::from_fn_with_state(state.clone(), authenticate));
    Router::new()
        .merge(protected)
        .route("/healthz", get(|| async { Json(json!({"status":"ok"})) }))
        .route("/derivatives/local-download/{token}", get(local_download))
        .route("/derivatives/local-playback/{token}", get(local_playback))
        .route(
            "/derivatives/local-upload/{token}",
            axum::routing::put(crate::edits::upload),
        )
        .route(
            "/derivatives/local-standard/{token}",
            get(standard_download),
        )
        .layer(DefaultBodyLimit::max(64 * 1024))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn authenticate(
    State(state): State<Arc<AppState>>,
    Path(params): Path<HashMap<String, String>>,
    request: Request,
    next: Next,
) -> Response {
    let expected = format!("Bearer {}", state.access_token);
    if request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        != Some(expected.as_str())
    {
        return ApiError(
            StatusCode::UNAUTHORIZED,
            "unauthorized".into(),
            "valid Bearer token required".into(),
        )
        .into_response();
    }
    if let Some(library) = params.get("library")
        && let Err(error) = require_library(&state, library)
    {
        return error.into_response();
    }
    next.run(request).await
}

pub(crate) fn require_library(state: &AppState, library: &str) -> Result<(), ApiError> {
    if library != state.library_id {
        return Err(ApiError(
            StatusCode::NOT_FOUND,
            "library_not_found".into(),
            "图库 ID 不存在，请检查连接设置中的图库 ID；此字段不是 NAS 用户名。".into(),
        ));
    }
    Ok(())
}

pub(crate) async fn blocking<F, T>(operation: F) -> Result<T, ApiError>
where
    T: Send + 'static,
    F: FnOnce() -> anyhow::Result<T> + Send + 'static,
{
    tokio::task::spawn_blocking(operation)
        .await
        .map_err(anyhow::Error::from)?
        .map_err(ApiError::from)
}
async fn interactive<F, T>(operation: F) -> Result<T, ApiError>
where
    T: Send + 'static,
    F: FnOnce() -> anyhow::Result<T> + Send + 'static,
{
    blocking(move || crate::database::interactive(operation)).await
}
fn signed_asset(state: &AppState, mut asset: Value) -> anyhow::Result<Value> {
    let preview = asset
        .as_object_mut()
        .and_then(|a| a.remove("_preview"))
        .unwrap_or(Value::Null);
    asset["preview"] = if preview.is_null() {
        Value::Null
    } else {
        json!({"downloadURL":state.previews.download_url(&preview["objectRef"])?,"width":preview["width"],"height":preview["height"],"version":preview["version"]})
    };
    if let Some(id) = asset["id"].as_str().map(str::to_owned) {
        let media = state.store.media_snapshot(&state.library_id, &id)?;
        asset["negativeContentHash"] = media["negativeContentHash"].clone();
        if !media["thumbnail"].is_null() {
            let d = &media["thumbnail"];
            asset["thumbnail"] = json!({"downloadURL":state.previews.download_url(&d["objectRef"])?,"width":d["width"],"height":d["height"],"version":d["version"]});
            asset["standard"] =
                standard_descriptor(state, &state.library_id, &id, &media["standard"])?;
        }
        asset["browseThumbnail"] = if media["browse"].is_null() {
            Value::Null
        } else {
            let d = &media["browse"];
            json!({"downloadURL":state.previews.download_url(&d["objectRef"])?,"width":d["width"],"height":d["height"],"version":d["version"]})
        };
    }
    Ok(asset)
}
pub(crate) fn asset_id(id: &str) -> Result<String, ApiError> {
    uuid::Uuid::parse_str(id)
        .map(|id| id.to_string())
        .map_err(|_| ApiError::bad("invalid asset UUID"))
}
async fn assets(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Query(mut query): Query<crate::catalog::AssetQuery>,
) -> ApiResult {
    Ok(Json(
        interactive(move || {
            if let Some(id) = &query.folder_id {
                query.directory = Some(folder_for(&state, &library, id)?.path);
            }
            let mut page = state.store.query_assets(&library, &query)?;
            for asset in page["items"].as_array_mut().expect("catalog page") {
                *asset = signed_asset(&state, asset.take())?;
            }
            Ok(page)
        })
        .await?,
    )
    .into_response())
}
async fn asset(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> ApiResult {
    let id = asset_id(&id)?;
    Ok(
        Json(interactive(move || signed_asset(&state, state.store.asset(&library, &id)?)).await?)
            .into_response(),
    )
}
fn metadata_guard(jobs: &crate::jobs::Jobs) -> anyhow::Result<std::sync::RwLockReadGuard<'_, ()>> {
    jobs.directory_mutation
        .try_read()
        .map_err(|error| match error {
            std::sync::TryLockError::WouldBlock => {
                resource_error(409, "目录移动或回收正在进行，请稍后重试此状态修改")
            }
            std::sync::TryLockError::Poisoned(_) => {
                anyhow::anyhow!("directory mutation lock poisoned")
            }
        })
}
async fn tag_library(State(state): State<Arc<AppState>>, Path(library): Path<String>) -> ApiResult {
    Ok(Json(interactive(move || state.store.tag_library(&library)).await?).into_response())
}
async fn add_tags_to_library(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Json(body): Json<Value>,
) -> ApiResult {
    Ok(
        Json(interactive(move || state.store.add_tags_to_library(&library, &body)).await?)
            .into_response(),
    )
}
async fn patch_asset(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
    Json(patch): Json<Value>,
) -> ApiResult {
    let id = asset_id(&id)?;
    Ok(Json(
        interactive(move || {
            let _guard = patch
                .get("flagState")
                .map(|_| metadata_guard(&state.jobs))
                .transpose()?;
            signed_asset(&state, state.store.patch_asset(&library, &id, &patch)?)
        })
        .await?,
    )
    .into_response())
}
async fn set_trashed(
    state: Arc<AppState>,
    library: String,
    id: String,
    trashed: bool,
) -> ApiResult {
    let id = asset_id(&id)?;
    Ok(Json(
        interactive(move || {
            let _guard = metadata_guard(&state.jobs)?;
            signed_asset(&state, state.store.set_trashed(&library, &id, trashed)?)
        })
        .await?,
    )
    .into_response())
}
async fn trash_asset(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> ApiResult {
    set_trashed(state, library, id, true).await
}
async fn restore_asset(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> ApiResult {
    set_trashed(state, library, id, false).await
}
#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CountsQuery {
    #[serde(default)]
    show_hidden: bool,
}
async fn counts(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Query(query): Query<CountsQuery>,
) -> ApiResult {
    Ok(
        Json(blocking(move || state.store.counts(&library, query.show_hidden)).await?)
            .into_response(),
    )
}
async fn hidden_directories(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
) -> ApiResult {
    Ok(Json(blocking(move || state.store.hidden_directories(&library)).await?).into_response())
}
#[derive(Deserialize)]
struct HiddenDirectoryChange {
    path: String,
    hidden: bool,
}
async fn set_hidden_directory(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Json(change): Json<HiddenDirectoryChange>,
) -> ApiResult {
    Ok(Json(
        interactive(move || {
            state
                .store
                .set_hidden_directory(&library, &change.path, change.hidden)
        })
        .await?,
    )
    .into_response())
}
async fn directories(State(state): State<Arc<AppState>>, Path(library): Path<String>) -> ApiResult {
    Ok(Json(blocking(move || state.store.directories(&library)).await?).into_response())
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateDirectoryRequest {
    parent_path: String,
    name: String,
}
#[derive(Deserialize)]
struct RefreshDirectoryRequest {
    path: String,
}
async fn refresh_directory(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Json(body): Json<RefreshDirectoryRequest>,
) -> ApiResult {
    let job = blocking(move || {
        let _directory_guard = metadata_guard(&state.jobs)?;
        crate::directory_move::ensure_reconciled(&state.jobs)?;
        let path = state
            .jobs
            .validate_path(std::path::Path::new(&body.path))
            .map_err(|error| resource_error(422, format!("{error:#}")))?;
        let folder = state
            .jobs
            .folders()?
            .into_iter()
            .filter(|folder| {
                folder.active && folder.library_id == library && path.starts_with(&folder.path)
            })
            .max_by_key(|folder| folder.path.len())
            .ok_or_else(|| resource_error(404, "directory is not tracked in this library"))?;
        Ok(serde_json::to_value(
            state
                .jobs
                .enqueue_manual_metadata_refresh(&folder.id, &path)?,
        )?)
    })
    .await?;
    Ok((StatusCode::ACCEPTED, Json(job)).into_response())
}
async fn create_directory(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Json(body): Json<CreateDirectoryRequest>,
) -> ApiResult {
    let result = blocking(move || {
        let _directory_guard = state.jobs.directory_mutation.read().unwrap();
        crate::directory_move::ensure_reconciled(&state.jobs)?;
        let name = &body.name;
        if name.trim().is_empty()
            || name.starts_with('.')
            || name == "@eaDir"
            || name == "#recycle"
            || name
                .chars()
                .any(|c| c == '/' || c == '\\' || c.is_control())
        {
            return Err(resource_error(
                422,
                "name must be a single visible folder name",
            ));
        }
        let parent = state
            .jobs
            .validate_path(std::path::Path::new(&body.parent_path))
            .map_err(|error| resource_error(422, format!("{error:#}")))?;
        if !state.jobs.folders()?.iter().any(|folder| {
            folder.active && folder.library_id == library && parent.starts_with(&folder.path)
        }) {
            return Err(resource_error(
                404,
                "directory is not tracked in this library",
            ));
        }
        let path = parent.join(name);
        std::fs::create_dir(&path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                resource_error(409, format!("create directory {}: {error}", path.display()))
            } else {
                anyhow::Error::from(error).context(format!("create directory {}", path.display()))
            }
        })?;
        Ok(json!({"path":path}))
    })
    .await?;
    Ok((StatusCode::CREATED, Json(result)).into_response())
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TrashDirectoryRequest {
    #[serde(default, rename = "requestID")]
    request_id: String,
    path: String,
    confirmation_name: String,
}
async fn trash_directory(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Json(body): Json<TrashDirectoryRequest>,
) -> ApiResult {
    let result = blocking(move || {
        Ok(serde_json::to_value(crate::directory_trash::submit(
            &state.jobs,
            &library,
            &body.path,
            &body.confirmation_name,
            &body.request_id,
        )?)?)
    })
    .await?;
    Ok((StatusCode::ACCEPTED, Json(result)).into_response())
}
async fn directory_trash_status(
    State(state): State<Arc<AppState>>,
    Path((library, request_id)): Path<(String, String)>,
) -> ApiResult {
    let result = blocking(move || {
        Ok(serde_json::to_value(crate::directory_trash::get(
            &state.jobs,
            &library,
            &request_id,
        )?)?)
    })
    .await?;
    Ok(Json(result).into_response())
}
#[derive(Deserialize)]
struct NavigationQuery {
    path: Option<String>,
}
async fn navigation(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Query(query): Query<NavigationQuery>,
) -> ApiResult {
    Ok(Json(
        blocking(move || {
            let mut result = crate::navigation::navigation(
                &state.jobs,
                &library,
                query.path.as_deref(),
                &state.original_root_names,
            )?;
            let directories = result["directories"]
                .as_array_mut()
                .expect("navigation directories");
            let paths: Vec<String> = directories
                .iter()
                .map(|directory| {
                    directory["path"]
                        .as_str()
                        .expect("navigation path")
                        .to_owned()
                })
                .collect();
            let counts = state.store.directory_photo_counts(&library, &paths)?;
            for (directory, (direct, recursive)) in directories.iter_mut().zip(counts) {
                directory["directPhotoCount"] = json!(direct);
                directory["photoCount"] = json!(recursive);
            }
            Ok(result)
        })
        .await?,
    )
    .into_response())
}
fn resource_error(status: u16, message: impl Into<String>) -> anyhow::Error {
    crate::store::StoreError {
        status,
        code: "invalid_request".into(),
        message: message.into(),
    }
    .into()
}
fn folder_for(state: &AppState, library: &str, id: &str) -> anyhow::Result<crate::jobs::Folder> {
    state
        .jobs
        .folders()?
        .into_iter()
        .find(|f| f.id == id && f.library_id == library)
        .ok_or_else(|| resource_error(404, "folder not found"))
}
async fn folders(State(state): State<Arc<AppState>>, Path(library): Path<String>) -> ApiResult {
    Ok(Json(blocking(move || Ok(json!({"rootPath":state.jobs.root(),"folders":state.jobs.folders()?.into_iter().filter(|f|f.library_id==library&&f.active).collect::<Vec<_>>()}))).await?).into_response())
}
#[derive(Deserialize)]
struct FolderRequest {
    path: String,
}
async fn add_folder(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Json(body): Json<FolderRequest>,
) -> ApiResult {
    Ok((
        StatusCode::CREATED,
        Json(
            blocking(move || {
                let _directory_guard = state.jobs.directory_mutation.read().unwrap();
                crate::directory_move::ensure_reconciled(&state.jobs)?;
                state
                    .jobs
                    .validate_path(std::path::Path::new(&body.path))
                    .map_err(|e| resource_error(422, format!("{e:#}")))?;
                let folder = state.jobs.add_folder(&library, &body.path)?;
                Ok(serde_json::to_value(folder)?)
            })
            .await?,
        ),
    )
        .into_response())
}
async fn remove_folder(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> ApiResult {
    blocking(move || {
        folder_for(&state, &library, &id)?;
        state.jobs.remove_folder(&id)?;
        Ok(Value::Null)
    })
    .await?;
    Ok(StatusCode::NO_CONTENT.into_response())
}
async fn scan_folder(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> ApiResult {
    Ok((
        StatusCode::ACCEPTED,
        Json(
            blocking(move || {
                let folder = folder_for(&state, &library, &id)?;
                if !folder.active {
                    return Err(resource_error(409, "folder is inactive"));
                }
                Ok(serde_json::to_value(state.jobs.enqueue_scan(&id)?)?)
            })
            .await?,
        ),
    )
        .into_response())
}
async fn jobs(State(state): State<Arc<AppState>>, Path(library): Path<String>) -> ApiResult {
    Ok(Json(
        blocking(move || Ok(json!({"jobs":state.jobs.jobs_for_library(&library,100)?}))).await?,
    )
    .into_response())
}
async fn retry_job(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> ApiResult {
    Ok(Json(
        blocking(move || {
            let job = state
                .jobs
                .job(&id)?
                .filter(|j| j.library_id == library)
                .ok_or_else(|| resource_error(404, "job not found"))?;
            if job.status != "failed" {
                return Err(resource_error(409, "only failed jobs can be retried"));
            }
            Ok(serde_json::to_value(
                state
                    .jobs
                    .retry(&id)
                    .map_err(|e| resource_error(409, format!("{e:#}")))?,
            )?)
        })
        .await?,
    )
    .into_response())
}
#[derive(Deserialize)]
struct DerivativeQuery {
    role: String,
    #[serde(rename = "libraryID")]
    library: Option<String>,
}
fn validate_derivative(asset: &str, role: &str) -> Result<String, ApiError> {
    let asset = uuid::Uuid::parse_str(asset).map_err(|_| {
        ApiError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid_request".into(),
            "invalid asset UUID".into(),
        )
    })?;
    if !["preview", "thumbnail", "browse", "standard"].contains(&role) {
        return Err(ApiError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid_request".into(),
            "invalid derivative role".into(),
        ));
    }
    Ok(asset.to_string())
}
async fn derivative_metadata(
    State(state): State<Arc<AppState>>,
    Path(asset): Path<String>,
    Query(query): Query<DerivativeQuery>,
) -> ApiResult {
    if let Some(library) = &query.library {
        require_library(&state, library)?;
    }
    let asset = validate_derivative(&asset, &query.role)?;
    let result = blocking(move || {
        if query.role == "browse" {
            let library=query.library.as_deref().unwrap_or(&state.library_id);
            return match state.store.browse_descriptor(library,&asset)? {
                Some(d) => Ok(json!({"downloadURL":state.previews.download_url(&d["objectRef"])?,"width":d["width"],"height":d["height"],"version":d["version"]})),
                None => Ok(Value::Null),
            };
        }
        if query.role != "preview" {
            let library=query.library.as_deref().unwrap_or(&state.library_id);
            if let Some((thumbnail,standard))=state.store.cache_descriptors(library,&asset)? {
                return if query.role=="standard" { standard_descriptor(&state,library,&asset,&standard) } else { Ok(json!({"downloadURL":state.previews.download_url(&thumbnail["objectRef"])?,"width":thumbnail["width"],"height":thumbnail["height"],"version":thumbnail["version"]})) };
            }
            return Ok(Value::Null);
        }
        let Some(derivative) =
            state
                .store
                .derivative_metadata(query.library.as_deref(), &asset, &query.role)?
        else {
            return Ok(Value::Null);
        };
        let url = state.previews.download_url(&derivative["objectRef"])?;
        Ok(json!({
            "downloadURL": url,
            "width": derivative["pixelSize"]["width"],
            "height": derivative["pixelSize"]["height"],
            "version": derivative["fileObject"]["contentHash"],
            "derivative": derivative
        }))
    })
    .await?;
    if result.is_null() {
        return Err(ApiError(
            StatusCode::NOT_FOUND,
            "derivative_not_found".into(),
            "derivative metadata not declared".into(),
        ));
    }
    Ok(Json(result).into_response())
}
async fn local_download(
    State(state): State<Arc<AppState>>,
    Path(token): Path<String>,
) -> ApiResult {
    let content = tokio::task::spawn_blocking(move || state.previews.read(&token))
        .await
        .map_err(anyhow::Error::from)??;
    Ok((
        [(header::CONTENT_TYPE, "application/octet-stream")],
        content,
    )
        .into_response())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RevisionQuery {
    path: Option<String>,
    #[serde(default)]
    include_children: bool,
}
async fn revision(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Query(query): Query<RevisionQuery>,
) -> ApiResult {
    Ok(Json(
        interactive(move || {
            state
                .store
                .catalog_revision(&library, query.path.as_deref(), query.include_children)
        })
        .await?,
    )
    .into_response())
}
async fn versions(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> ApiResult {
    let id = asset_id(&id)?;
    Ok(Json(blocking(move || state.store.versions(&library, &id)).await?).into_response())
}
fn open_version_source(
    state: &AppState,
    library: &str,
    id: &str,
    hash: &str,
) -> anyhow::Result<(std::fs::File, &'static str)> {
    let validation_error = |error: ApiError| {
        anyhow::Error::new(crate::store::StoreError {
            status: error.0.as_u16(),
            code: error.1,
            message: error.2,
        })
    };
    require_library(state, library).map_err(validation_error)?;
    let id = asset_id(id).map_err(validation_error)?;
    if hash.len() != 64
        || !hash
            .bytes()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
    {
        return Err(resource_error(400, "invalid content hash"));
    }
    let paths = state.store.available_version_paths(library, &id, hash)?;
    if paths.is_empty() {
        return Err(resource_error(404, "version not available for this asset"));
    }
    let folders = state.jobs.folders()?;
    for raw_path in &paths {
        let path = std::path::Path::new(raw_path);
        let Some(folder) = folders
            .iter()
            .find(|f| f.active && f.library_id == library && path.starts_with(&f.path))
        else {
            continue;
        };
        let Some(record) = state.jobs.file_state(&folder.id, raw_path)? else {
            continue;
        };
        if record.asset_id != id || record.version != hash || record.error.is_some() {
            continue;
        }
        let Ok(metadata) = std::fs::symlink_metadata(path) else {
            continue;
        };
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err(resource_error(409, "version source is not a regular file"));
        }
        state.jobs.validate_path(
            path.parent()
                .ok_or_else(|| resource_error(409, "missing source parent"))?,
        )?;
        let file = std::fs::File::open(path)?;
        let metadata = file.metadata()?;
        let modified = metadata
            .modified()?
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos();
        if metadata.len() != record.size as u64 || modified != record.mtime_ns as u128 {
            return Err(resource_error(
                409,
                "version source changed; refresh inventory",
            ));
        }
        return Ok((file, video_mime(path)));
    }
    Err(resource_error(404, "tracked version source unavailable"))
}
fn video_mime(path: &std::path::Path) -> &'static str {
    match path
        .extension()
        .and_then(|v| v.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "mkv" => "video/x-matroska",
        "avi" => "video/x-msvideo",
        "mts" | "m2ts" | "ts" => "video/mp2t",
        "mpg" | "mpeg" => "video/mpeg",
        _ => "application/octet-stream",
    }
}

async fn version_playback(
    State(state): State<Arc<AppState>>,
    Path((library, id, hash)): Path<(String, String, String)>,
) -> ApiResult {
    Ok(Json(
        blocking(move || {
            open_version_source(&state, &library, &id, &hash)?;
            state.previews.playback_descriptor(&library, &id, &hash)
        })
        .await?,
    )
    .into_response())
}

async fn local_playback(
    State(state): State<Arc<AppState>>,
    Path(token): Path<String>,
    method: Method,
    headers: HeaderMap,
) -> ApiResult {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let (file, mime, hash) = blocking(move || {
        let payload = state.previews.verify(&token, "playback")?;
        let (file, mime) = open_version_source(
            &state,
            payload["library"].as_str().unwrap(),
            payload["asset"].as_str().unwrap(),
            payload["hash"].as_str().unwrap(),
        )?;
        Ok((file, mime, payload["hash"].as_str().unwrap().to_owned()))
    })
    .await?;
    let mut file = tokio::fs::File::from_std(file);
    let length = file.metadata().await.map_err(anyhow::Error::from)?.len();
    let etag = format!("\"{hash}\"");
    let requested = headers.get(header::RANGE).filter(|value| {
        method == Method::GET
            && value
                .to_str()
                .is_ok_and(|value| value.starts_with("bytes="))
            && headers
                .get(header::IF_RANGE)
                .is_none_or(|v| v.to_str().ok() == Some(etag.as_str()))
    });
    let selected = if let Some(value) = requested {
        match value
            .to_str()
            .ok()
            .and_then(|v| crate::offline_rebuild::range(v, length).ok())
        {
            Some(range) => Some(range),
            None => {
                return Ok((
                    StatusCode::RANGE_NOT_SATISFIABLE,
                    [
                        (header::CONTENT_RANGE, format!("bytes */{length}")),
                        (header::ACCEPT_RANGES, "bytes".into()),
                        (header::ETAG, etag),
                    ],
                )
                    .into_response());
            }
        }
    } else {
        None
    };
    let (start, count) = selected
        .map(|(start, end)| (start, end - start + 1))
        .unwrap_or((0, length));
    let body = if method == Method::HEAD {
        axum::body::Body::empty()
    } else {
        file.seek(std::io::SeekFrom::Start(start))
            .await
            .map_err(anyhow::Error::from)?;
        axum::body::Body::from_stream(tokio_util::io::ReaderStream::new(file.take(count)))
    };
    let mut response = body.into_response();
    *response.status_mut() = if selected.is_some() {
        StatusCode::PARTIAL_CONTENT
    } else {
        StatusCode::OK
    };
    for (key, value) in [
        (header::CONTENT_TYPE, mime.to_owned()),
        (header::CONTENT_LENGTH, count.to_string()),
        (header::ACCEPT_RANGES, "bytes".into()),
        (header::ETAG, etag),
        (header::CACHE_CONTROL, "private, no-store".into()),
    ] {
        response
            .headers_mut()
            .insert(key, value.parse().map_err(anyhow::Error::from)?);
    }
    if let Some((start, end)) = selected {
        response.headers_mut().insert(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{length}")
                .parse()
                .map_err(anyhow::Error::from)?,
        );
    }
    Ok(response)
}

async fn version_download(
    State(state): State<Arc<AppState>>,
    Path((library, id, hash)): Path<(String, String, String)>,
) -> ApiResult {
    let (file, _) = blocking(move || open_version_source(&state, &library, &id, &hash)).await?;
    let file = tokio::fs::File::from_std(file);
    let length = file.metadata().await.map_err(anyhow::Error::from)?.len();
    let body = axum::body::Body::from_stream(tokio_util::io::ReaderStream::new(file));
    Ok((
        [
            (header::CONTENT_TYPE, "application/octet-stream".to_owned()),
            (header::CONTENT_LENGTH, length.to_string()),
        ],
        body,
    )
        .into_response())
}
async fn version_candidates(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> ApiResult {
    let id = asset_id(&id)?;
    Ok(
        Json(blocking(move || state.store.version_candidates(&library, &id)).await?)
            .into_response(),
    )
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DefaultVersionChange {
    content_hash: String,
}
async fn default_version(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
    Json(change): Json<DefaultVersionChange>,
) -> ApiResult {
    let id = asset_id(&id)?;
    Ok(Json(
        interactive(move || {
            let versions = state.store.versions(&library, &id)?;
            let version = versions["items"]
                .as_array()
                .and_then(|items| {
                    items.iter().find(|version| {
                        version["contentHash"].as_str() == Some(&change.content_hash)
                            && version["available"] == true
                    })
                })
                .ok_or_else(|| resource_error(422, "version is not available for this asset"))?;
            let folders = state.jobs.folders()?;
            let target = version["paths"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|location| location["available"] == true)
                .filter_map(|location| location["path"].as_str())
                .find_map(|path| {
                    folders
                        .iter()
                        .find(|folder| {
                            folder.active
                                && folder.library_id == library
                                && std::path::Path::new(path).starts_with(&folder.path)
                        })
                        .map(|folder| (folder.id.clone(), path))
                })
                .ok_or_else(|| {
                    resource_error(
                        409,
                        "version folder is not tracked; enable tracking before selecting a default",
                    )
                })?;
            let scope = std::path::Path::new(target.1)
                .parent()
                .ok_or_else(|| resource_error(422, "version path has no parent"))?;
            state
                .jobs
                .validate_path(scope)
                .map_err(|error| resource_error(409, format!("{error:#}")))?;
            let result = state
                .store
                .set_default_version(&library, &id, &change.content_hash)?;
            state
                .jobs
                .enqueue_operation_file(&target.0, std::path::Path::new(target.1), 0)?;
            Ok(result)
        })
        .await?,
    )
    .into_response())
}

pub(crate) fn standard_descriptor(
    state: &AppState,
    library: &str,
    asset: &str,
    standard: &Value,
) -> anyhow::Result<Value> {
    if standard["deferred"].as_bool() == Some(true)
        || crate::media::is_video(std::path::Path::new(
            standard["path"].as_str().unwrap_or(""),
        ))
    {
        return Ok(Value::Null);
    }
    if !standard["objectRef"].is_null() {
        return Ok(
            json!({"downloadURL":state.previews.download_url(&standard["objectRef"])?,"width":standard["width"],"height":standard["height"],"version":standard["version"]}),
        );
    }
    let object = json!({"bucket":"keeps-previews","key":format!("libraries/{library}/assets/{asset}/standard/{}",standard["version"].as_str().unwrap_or(""))});
    Ok(
        json!({"downloadURL":state.previews.signed_url(&object,"standard")?,"width":standard["width"],"height":standard["height"],"version":standard["version"]}),
    )
}
async fn standard_download(
    State(state): State<Arc<AppState>>,
    Path(token): Path<String>,
) -> ApiResult {
    let (path, mime) = tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
        let payload = state.previews.verify(&token, "standard")?;
        let parts: Vec<_> = payload["key"].as_str().unwrap_or("").split('/').collect();
        anyhow::ensure!(
            parts.len() == 6
                && parts[0] == "libraries"
                && parts[2] == "assets"
                && parts[4] == "standard",
            "invalid standard token"
        );
        anyhow::ensure!(parts[1] == state.library_id, "wrong library");
        let (_, standard) = state
            .store
            .cache_descriptors(parts[1], parts[3])?
            .ok_or_else(|| anyhow::anyhow!("standard no longer available"))?;
        anyhow::ensure!(
            standard["deferred"].as_bool() != Some(true),
            "standard generation deferred"
        );
        anyhow::ensure!(standard["version"] == parts[5], "standard version changed");
        let path = std::path::PathBuf::from(
            standard["path"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("missing standard path"))?,
        );
        anyhow::ensure!(
            !std::fs::symlink_metadata(&path)?.file_type().is_symlink(),
            "standard symlink forbidden"
        );
        anyhow::ensure!(
            std::fs::metadata(&path)?.len() == standard["sizeBytes"].as_u64().unwrap_or(0)
                && crate::cache_pipeline::file_mtime(&path)?
                    == standard["mtimeNs"].as_str().unwrap_or(""),
            "standard source changed; waiting for inventory refresh"
        );
        let path = path.canonicalize()?;
        state.jobs.validate_path(
            path.parent()
                .ok_or_else(|| anyhow::anyhow!("standard has no parent directory"))?,
        )?;
        let mime = match path
            .extension()
            .and_then(|v| v.to_str())
            .unwrap_or("")
            .to_lowercase()
            .as_str()
        {
            "jpg" | "jpeg" => "image/jpeg",
            "png" => "image/png",
            "tif" | "tiff" => "image/tiff",
            "gif" => "image/gif",
            "webp" => "image/webp",
            "avif" => "image/avif",
            "heif" | "hif" => "image/heif",
            "mov" => "video/quicktime",
            "mp4" | "m4v" => "video/mp4",
            "avi" => "video/x-msvideo",
            "mkv" => "video/x-matroska",
            "mts" | "m2ts" => "video/mp2t",
            _ => "image/heic",
        };
        Ok((path, mime))
    })
    .await
    .map_err(anyhow::Error::from)??;
    let file = tokio::fs::File::open(path)
        .await
        .map_err(anyhow::Error::from)?;
    let length = file.metadata().await.map_err(anyhow::Error::from)?.len();
    let body = axum::body::Body::from_stream(tokio_util::io::ReaderStream::new(file));
    Ok((
        [
            (header::CONTENT_TYPE, mime.to_string()),
            (header::CONTENT_LENGTH, length.to_string()),
        ],
        body,
    )
        .into_response())
}
async fn cache_status(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
) -> ApiResult {
    require_library(&state, &library)?;
    Ok(Json(
        blocking(move || {
            let mut result = state.store.cache_status(&library)?;
            result["identityBackfill"] = state.jobs.identity_status(&library)?;
            Ok(result)
        })
        .await?,
    )
    .into_response())
}
async fn cache_retry(State(state): State<Arc<AppState>>, Path(library): Path<String>) -> ApiResult {
    require_library(&state, &library)?;
    Ok(
        Json(blocking(move || Ok(json!({"requeued":crate::cache_pipeline::queue_manual(&state.store,&state.jobs,&library,false)?,"gcRequeued":state.store.retry_cache_garbage(&library)?}))).await?)
            .into_response(),
    )
}

async fn cache_rebuild(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
) -> ApiResult {
    require_library(&state, &library)?;
    Ok(
        Json(blocking(move || Ok(json!({"requeued":crate::cache_pipeline::queue_manual(&state.store,&state.jobs,&library,true)?}))).await?)
            .into_response(),
    )
}

async fn task_status(State(state): State<Arc<AppState>>, Path(library): Path<String>) -> ApiResult {
    require_library(&state, &library)?;
    Ok(
        Json(interactive(move || crate::tasks::status(&state.store, &state.jobs, &library)).await?)
            .into_response(),
    )
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MoveDirectoryRequest {
    name: Option<String>,
    path: String,
    parent_path: String,
    #[serde(rename = "requestID")]
    request_id: String,
}
async fn move_directory(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Json(body): Json<MoveDirectoryRequest>,
) -> ApiResult {
    Ok(Json(
        blocking(move || {
            crate::directory_move::move_directory(
                &state.jobs,
                &state.store,
                &library,
                &body.path,
                &body.parent_path,
                &body.request_id,
                body.name.as_deref(),
            )
        })
        .await?,
    )
    .into_response())
}

async fn submit_directory_move(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Json(body): Json<MoveDirectoryRequest>,
) -> ApiResult {
    let result = blocking(move || {
        crate::directory_move::submit(
            &state.jobs,
            &library,
            &body.path,
            &body.parent_path,
            &body.request_id,
            body.name.as_deref(),
        )
    })
    .await?;
    Ok((StatusCode::ACCEPTED, Json(result)).into_response())
}
async fn directory_move_status(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> ApiResult {
    Ok(
        Json(blocking(move || crate::directory_move::get(&state.jobs, &library, &id)).await?)
            .into_response(),
    )
}

async fn submit_asset_move(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Json(body): Json<crate::asset_move::Request>,
) -> ApiResult {
    require_library(&state, &library)?;
    let result = blocking(move || crate::asset_move::submit(&state.jobs, &library, body)).await?;
    Ok((StatusCode::ACCEPTED, Json(result)).into_response())
}
async fn asset_move_status(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> ApiResult {
    require_library(&state, &library)?;
    Ok(
        Json(blocking(move || crate::asset_move::get(&state.jobs, &library, &id)).await?)
            .into_response(),
    )
}

#[cfg(test)]
mod priority_tests {
    use super::*;

    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // Simulate a directory operation blocking API worker threads.
    async fn metadata_requests_do_not_wait_for_directory_work() -> anyhow::Result<()> {
        let dir = tempfile::tempdir()?;
        let originals = dir.path().join("photos");
        std::fs::create_dir(&originals)?;
        let keeps = dir.path().join("keeps");
        let token = "test-priority";
        let previews = Arc::new(PreviewStorage::new(
            &keeps,
            Some(&originals),
            "http://localhost",
            token,
        )?);
        let store = Arc::new(Store::open(&keeps.join("db/catalog.sqlite"), true)?);
        let jobs = Arc::new(crate::jobs::Jobs::open(
            &keeps.join("db/jobs.sqlite"),
            &originals,
        )?);
        let id = store.ingest_original("lib", "/sample.jpg", &json!({"contentHash":"sample","sizeBytes":1,"role":"jpeg_original"}), &json!({"contentFingerprint":"sample","metadataFingerprint":"sample","originalFilename":"sample.jpg","rating":0,"tags":[],"flagState":"unflagged","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"}))?;
        let state = Arc::new(AppState {
            store,
            jobs: jobs.clone(),
            previews,
            access_token: token.into(),
            library_id: "lib".into(),
            original_root_names: Default::default(),
        });
        let _directory = jobs.directory_mutation.write().unwrap();
        for (patch, expected) in [
            (json!({"rating":5,"tags":["edited"]}), StatusCode::OK),
            (json!({"flagState":"rejected"}), StatusCode::CONFLICT),
        ] {
            let response = tokio::time::timeout(
                std::time::Duration::from_secs(2),
                patch_asset(
                    State(state.clone()),
                    Path(("lib".into(), id.clone())),
                    Json(patch),
                ),
            )
            .await?;
            assert_eq!(
                response
                    .unwrap_or_else(IntoResponse::into_response)
                    .status(),
                expected
            );
        }
        let response = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            set_trashed(state.clone(), "lib".into(), id.clone(), true),
        )
        .await?;
        assert_eq!(
            response
                .unwrap_or_else(IntoResponse::into_response)
                .status(),
            StatusCode::CONFLICT
        );
        assert_eq!(state.store.asset("lib", &id)?["rating"], 5);
        assert_eq!(state.store.asset("lib", &id)?["flagState"], "unflagged");
        Ok(())
    }
}
