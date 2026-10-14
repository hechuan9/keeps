use anyhow::{Context, Result, bail, ensure};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::Sha256;
use std::{
    fs,
    io::Write,
    path::{Component, Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

const BUCKET: &str = "keeps-previews";
const TOKEN_LIFETIME: u64 = 15 * 60;

#[derive(Debug)]
pub struct PreviewError {
    pub status: u16,
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for PreviewError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for PreviewError {}

impl PreviewError {
    fn input(message: impl Into<String>) -> Self {
        Self {
            status: 422,
            code: "invalid_derivative_request".into(),
            message: message.into(),
        }
    }
    fn token(message: impl Into<String>) -> Self {
        Self {
            status: 400,
            code: "invalid_derivative_storage_token".into(),
            message: message.into(),
        }
    }
}

pub struct PreviewStorage {
    root: PathBuf,
    base_url: String,
    signing_key: Vec<u8>,
}

impl PreviewStorage {
    pub fn new(
        root: &Path,
        original: Option<&Path>,
        base_url: &str,
        signing_key: &str,
    ) -> Result<Self> {
        ensure!(!signing_key.is_empty(), "preview signing key is required");
        let url = url::Url::parse(base_url).context("invalid public base URL")?;
        ensure!(
            matches!(url.scheme(), "http" | "https")
                && url.host_str().is_some()
                && url.query().is_none()
                && url.fragment().is_none(),
            "invalid public base URL"
        );
        let root = resolve_future_path(root)?;
        if let Some(original) = original {
            let original = fs::canonicalize(original).context("resolve original photo root")?;
            ensure!(
                !root.starts_with(&original) && !original.starts_with(&root),
                "original and keeps roots must not contain one another"
            );
        }
        fs::create_dir_all(&root).context("create keeps root")?;
        for name in ["db", "previews", "backups", "tmp"] {
            let path = root.join(name);
            reject_symlink(&path)?;
            fs::create_dir_all(&path).with_context(|| format!("create {}", path.display()))?;
        }
        Ok(Self {
            root: root.join("previews"),
            base_url: base_url.trim_end_matches('/').into(),
            signing_key: signing_key.as_bytes().to_vec(),
        })
    }

    pub(crate) fn keeps_root(&self) -> &Path {
        self.root.parent().expect("preview root has parent")
    }

    pub fn free_bytes(&self) -> Result<i64> {
        crate::cache_pipeline::free_bytes(&self.root)
    }

    pub fn upload(&self, request: &Value) -> Result<Value> {
        let (library, asset) = validate_upload(request).map_err(|error| {
            let message = error.to_string();
            error.context(PreviewError::input(message))
        })?;
        let key = format!(
            "libraries/{library}/assets/{asset}/derivatives/preview/{}.heic",
            Uuid::new_v4().simple()
        );
        let object = json!({"bucket": BUCKET, "key": key});
        let upload_url = self.signed_url(&object, "upload")?;
        Ok(
            json!({"libraryID": library, "assetID": asset, "role": "preview", "fileObject": request["fileObject"], "objectRef": object, "uploadURL": upload_url}),
        )
    }

    pub fn download_url(&self, object_ref: &Value) -> Result<String> {
        self.signed_url(object_ref, "download")
    }

    pub(crate) fn playback_descriptor(
        &self,
        library: &str,
        asset: &str,
        hash: &str,
    ) -> Result<Value> {
        let expires = now()? + 24 * 60 * 60;
        let payload = json!({"library": library, "asset": asset, "hash": hash, "operation": "playback", "expires": expires});
        Ok(json!({"playbackURL": self.sign_payload(&payload, "playback")?, "expiresAt": expires}))
    }

    pub fn write(&self, token: &str, bytes: &[u8]) -> Result<()> {
        let object = self.verify(token, "upload")?;
        let path = self.object_path(&object)?;
        let parent = path.parent().context("preview parent missing")?;
        fs::create_dir_all(parent).context("create preview directories")?;
        self.object_path(&object)?;
        // Atomic replacement never follows an existing file's hard link into the original library.
        let mut temporary =
            tempfile::NamedTempFile::new_in(parent).context("create preview temporary file")?;
        temporary.write_all(bytes).context("write preview")?;
        temporary.as_file().sync_all().context("flush preview")?;
        temporary.persist(&path).context("publish preview")?;
        Ok(())
    }

    pub fn contains(&self, object_ref: &Value) -> Result<bool> {
        Ok(self.object_path(object_ref)?.is_file())
    }

    pub fn put_generated(
        &self,
        library: &str,
        asset: &str,
        hash: &str,
        source: &Path,
    ) -> Result<Value> {
        self.put_generated_role(library, asset, hash, source, "preview")
    }
    pub fn put_generated_role(
        &self,
        library: &str,
        asset: &str,
        hash: &str,
        source: &Path,
        role: &str,
    ) -> Result<Value> {
        ensure!(
            ["preview", "thumbnail", "browse"].contains(&role),
            "invalid generated role"
        );
        let object = json!({"bucket":BUCKET,"key":format!("libraries/{library}/assets/{asset}/derivatives/{role}/{hash}.heic")});
        let token = self.signed_url(&object, "upload")?;
        self.write(
            token
                .rsplit('/')
                .next()
                .context("invalid generated token")?,
            &fs::read(source)?,
        )?;
        Ok(object)
    }

    pub fn read(&self, token: &str) -> Result<Vec<u8>> {
        let object = self.verify(token, "download")?;
        fs::read(self.object_path(&object)?).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                anyhow::Error::new(error).context(PreviewError {
                    status: 404,
                    code: "derivative_object_not_found".into(),
                    message: "preview object not found".into(),
                })
            } else {
                anyhow::Error::new(error).context("read preview")
            }
        })
    }

    pub fn delete(&self, object_ref: &Value) -> Result<()> {
        let path = self.object_path(object_ref)?;
        match fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error).context("remove preview"),
        }
    }

    pub(crate) fn object_path(&self, object: &Value) -> Result<PathBuf> {
        let key = validate_object(object).map_err(|error| {
            let message = error.to_string();
            error.context(PreviewError::input(message))
        })?;
        let mut path = self.root.clone();
        reject_symlink(&path)?;
        for part in Path::new(key).components() {
            path.push(part);
            reject_symlink(&path)?;
        }
        Ok(path)
    }

    pub(crate) fn signed_url(&self, object: &Value, operation: &str) -> Result<String> {
        self.object_path(object)?;
        let payload = json!({"bucket": text(object, "bucket")?, "key": text(object, "key")?, "operation": operation, "expires": now()? + TOKEN_LIFETIME});
        self.sign_payload(&payload, operation)
    }

    fn sign_payload(&self, payload: &Value, operation: &str) -> Result<String> {
        let encoded = URL_SAFE_NO_PAD.encode(serde_json::to_vec(payload)?);
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.signing_key)?;
        mac.update(encoded.as_bytes());
        let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
        Ok(format!(
            "{}/derivatives/local-{operation}/{encoded}.{signature}",
            self.base_url
        ))
    }

    pub(crate) fn verify(&self, token: &str, operation: &str) -> Result<Value> {
        let current_time = now()?;
        let (payload, expires) = (|| -> Result<(Value, u64)> {
            let (encoded, signature) = token.split_once('.').context("invalid preview token")?;
            let mut mac = Hmac::<Sha256>::new_from_slice(&self.signing_key)?;
            mac.update(encoded.as_bytes());
            mac.verify_slice(
                &URL_SAFE_NO_PAD
                    .decode(signature)
                    .context("invalid token signature")?,
            )
            .context("invalid token signature")?;
            let payload: Value = serde_json::from_slice(
                &URL_SAFE_NO_PAD
                    .decode(encoded)
                    .context("invalid token payload")?,
            )?;
            ensure!(payload["operation"] == operation, "invalid token operation");
            let expires = payload["expires"]
                .as_u64()
                .context("missing token expiry")?;
            if operation != "playback" {
                validate_object(&payload)?;
            } else {
                for field in ["library", "asset", "hash"] {
                    text(&payload, field)?;
                }
            }
            Ok((payload, expires))
        })()
        .map_err(|error| {
            let message = error.to_string();
            error.context(PreviewError::token(message))
        })?;
        if expires <= current_time {
            let error = anyhow::anyhow!("preview token expired");
            let context = if operation == "download" || operation == "standard" {
                PreviewError {
                    status: 403,
                    code: "preview_token_expired".into(),
                    message: error.to_string(),
                }
            } else {
                PreviewError::token(error.to_string())
            };
            return Err(error.context(context));
        }
        if operation != "playback" {
            self.object_path(&payload)?;
        }
        Ok(payload)
    }
}

fn validate_upload(request: &Value) -> Result<(&str, Uuid)> {
    ensure!(
        request["role"] == "preview",
        "only preview derivatives can be uploaded"
    );
    let library = text(request, "libraryID")?;
    ensure!(
        !library.is_empty()
            && !library.contains(['/', '\\', '\0'])
            && library != "."
            && library != "..",
        "invalid libraryID"
    );
    let asset = Uuid::parse_str(text(request, "assetID")?).context("invalid assetID")?;
    let file = &request["fileObject"];
    ensure!(
        !text(file, "contentHash")?.is_empty(),
        "contentHash must not be empty"
    );
    ensure!(
        file["sizeBytes"].as_i64().is_some_and(|value| value >= 0),
        "sizeBytes must be a nonnegative integer"
    );
    ensure!(
        matches!(
            text(file, "role")?,
            "raw_original"
                | "jpeg_original"
                | "sidecar"
                | "preview"
                | "thumbnail"
                | "browse"
                | "export"
        ),
        "invalid fileObject role"
    );
    for field in ["width", "height"] {
        ensure!(
            request["pixelSize"][field]
                .as_i64()
                .is_some_and(|value| value > 0),
            "pixelSize {field} must be a positive integer"
        );
    }
    Ok((library, asset))
}

fn validate_object(object: &Value) -> Result<&str> {
    ensure!(text(object, "bucket")? == BUCKET, "invalid preview bucket");
    let key = text(object, "key")?;
    ensure!(
        !key.is_empty()
            && !key.contains(['\\', '\0'])
            && key
                .split('/')
                .all(|part| !part.is_empty() && part != "." && part != ".."),
        "invalid preview key"
    );
    ensure!(
        Path::new(key)
            .components()
            .all(|part| matches!(part, Component::Normal(_))),
        "invalid preview key"
    );
    Ok(key)
}

fn text<'a>(value: &'a Value, field: &str) -> Result<&'a str> {
    value[field]
        .as_str()
        .with_context(|| format!("missing {field}"))
}

fn now() -> Result<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())
}

fn reject_symlink(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => ensure!(
            !metadata.file_type().is_symlink(),
            PreviewError::input(format!(
                "symlinks are forbidden in preview storage: {}",
                path.display()
            ))
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).with_context(|| format!("inspect {}", path.display())),
    }
    Ok(())
}

fn resolve_future_path(path: &Path) -> Result<PathBuf> {
    if path.exists() {
        return fs::canonicalize(path).context("resolve keeps root");
    }
    let name = path.file_name().context("invalid keeps root")?;
    let parent = path.parent().context("invalid keeps parent")?;
    if parent == path {
        bail!("invalid keeps root");
    }
    let parent = if parent.as_os_str().is_empty() {
        fs::canonicalize(".")?
    } else {
        resolve_future_path(parent)?
    };
    Ok(parent.join(name))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> Value {
        json!({"libraryID":"main", "assetID":Uuid::new_v4(), "role":"preview", "fileObject":{"contentHash":"abc", "sizeBytes":3, "role":"preview"}, "pixelSize":{"width":100,"height":100}})
    }
    fn token(url: &str) -> &str {
        url.rsplit('/').next().unwrap()
    }

    #[test]
    fn playback_tokens_are_scoped_expiring_and_operation_specific() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let storage = PreviewStorage::new(dir.path(), None, "http://localhost", "key")?;
        let descriptor = storage.playback_descriptor("library", "asset", "hash")?;
        let value = token(descriptor["playbackURL"].as_str().unwrap());
        let payload = storage.verify(value, "playback")?;
        assert_eq!(payload["library"], "library");
        assert_eq!(payload["asset"], "asset");
        assert_eq!(payload["hash"], "hash");
        assert_eq!(payload["expires"], descriptor["expiresAt"]);
        assert!(payload["expires"].as_u64().unwrap() >= now()? + 86399);
        assert!(storage.verify(value, "download").is_err());
        assert!(storage.verify(&format!("{value}x"), "playback").is_err());
        let mut expired = payload;
        expired["expires"] = json!(now()? - 1);
        let url = storage.sign_payload(&expired, "playback")?;
        assert!(storage.verify(token(&url), "playback").is_err());
        let preview = storage.upload(&request())?;
        let token = token(preview["uploadURL"].as_str().unwrap());
        assert!(storage.verify(token, "playback").is_err());
        let upload = storage.verify(token, "upload")?;
        assert!(upload["expires"].as_u64().unwrap() <= now()? + TOKEN_LIFETIME);
        Ok(())
    }

    #[test]
    fn round_trip_and_permissions() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let storage = PreviewStorage::new(dir.path(), None, "http://localhost:8000", "test-key")?;
        let upload = storage.upload(&request())?;
        let write_token = token(upload["uploadURL"].as_str().unwrap());
        storage.write(write_token, b"abc")?;
        assert!(storage.read(write_token).is_err());
        let download = storage.download_url(&upload["objectRef"])?;
        assert_eq!(storage.read(token(&download))?, b"abc");
        assert!(storage.write(token(&download), b"bad").is_err());
        assert!(storage.read(&format!("{}x", token(&download))).is_err());
        assert!(
            storage
                .read(&URL_SAFE_NO_PAD.encode(b"{\"bucket\":\"keeps-previews\",\"key\":\"x\"}"))
                .is_err()
        );
        storage.delete(&upload["objectRef"])?;
        assert_eq!(
            storage
                .read(token(&download))
                .unwrap_err()
                .downcast_ref::<PreviewError>()
                .unwrap()
                .status,
            404
        );
        Ok(())
    }

    #[test]
    fn reports_invalid_request_and_token_errors() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let storage = PreviewStorage::new(dir.path(), None, "http://localhost", "key")?;
        for (pointer, value) in [
            ("/fileObject/contentHash", json!(null)),
            ("/fileObject/sizeBytes", json!(-1)),
            ("/fileObject/role", json!("unknown")),
            ("/pixelSize/width", json!(0)),
            ("/pixelSize/height", json!("100")),
        ] {
            let mut request = request();
            *request.pointer_mut(pointer).unwrap() = value;
            assert_eq!(
                storage
                    .upload(&request)
                    .unwrap_err()
                    .downcast_ref::<PreviewError>()
                    .unwrap()
                    .status,
                422
            );
        }
        assert_eq!(
            storage
                .read("unsigned")
                .unwrap_err()
                .downcast_ref::<PreviewError>()
                .unwrap()
                .status,
            400
        );
        Ok(())
    }

    #[test]
    fn rejects_overlap_and_traversal() -> Result<()> {
        let dir = tempfile::tempdir()?;
        assert!(
            PreviewStorage::new(
                &dir.path().join("keeps"),
                Some(dir.path()),
                "http://localhost",
                "key"
            )
            .is_err()
        );
        assert!(!dir.path().join("keeps").exists());
        let original = dir.path().join("photos");
        fs::create_dir(&original)?;
        assert!(
            PreviewStorage::new(dir.path(), Some(&original), "http://localhost", "key").is_err()
        );
        let storage = PreviewStorage::new(
            &dir.path().join("keeps"),
            Some(&original),
            "http://localhost",
            "key",
        )?;
        for key in ["../photos/x", "/photos/x", "a/../x", "a//x", "a/./x"] {
            assert!(
                storage
                    .download_url(&json!({"bucket":BUCKET,"key":key}))
                    .is_err()
            );
        }
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&original, storage.root.join("escape"))?;
            assert!(
                storage
                    .delete(&json!({"bucket":BUCKET,"key":"escape/photo.jpg"}))
                    .is_err()
            );
            assert!(
                storage
                    .download_url(&json!({"bucket":BUCKET,"key":"escape/photo.jpg"}))
                    .is_err()
            );
        }
        Ok(())
    }

    #[test]
    fn rejects_expired_signed_token() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let storage = PreviewStorage::new(dir.path(), None, "http://localhost", "key")?;
        let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(
            &json!({"bucket":BUCKET,"key":"x","operation":"download","expires":now()? - 1}),
        )?);
        let mut mac = Hmac::<Sha256>::new_from_slice(b"key")?;
        mac.update(payload.as_bytes());
        let token = format!(
            "{payload}.{}",
            URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
        );
        let error = storage.read(&token).unwrap_err();
        let response = error.downcast_ref::<PreviewError>().unwrap();
        assert_eq!(response.status, 403);
        assert_eq!(response.code, "preview_token_expired");
        assert_eq!(error.root_cause().to_string(), "preview token expired");

        let tampered = token.replacen(&payload, &URL_SAFE_NO_PAD.encode(b"{}"), 1);
        let error = storage.read(&tampered).unwrap_err();
        let response = error.downcast_ref::<PreviewError>().unwrap();
        assert_eq!(response.status, 400);
        assert_eq!(response.code, "invalid_derivative_storage_token");
        assert!(format!("{error:#}").contains("invalid token signature"));
        Ok(())
    }
}
