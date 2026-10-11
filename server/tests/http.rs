use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use keeps_server::{
    api::{AppState, router},
    jobs::Jobs,
    previews::PreviewStorage,
    store::Store,
};
use serde_json::{Value, json};
use std::{path::Path, sync::Arc};
use tower::ServiceExt;

const SIGNING_KEY: &str = "test-preview-key-01234567890123456789";
fn state(root: &Path) -> Arc<AppState> {
    let originals = root.join("originals");
    std::fs::create_dir_all(&originals).unwrap();
    let keeps = root.join("keeps");
    let previews =
        PreviewStorage::new(&keeps, Some(&originals), "http://localhost", SIGNING_KEY).unwrap();
    let store = Store::open(&keeps.join("db/control_plane.sqlite"), true).unwrap();
    let jobs = Arc::new(Jobs::open(&keeps.join("db/jobs.sqlite"), &originals).unwrap());
    Arc::new(AppState {
        store: Arc::new(store),
        previews: Arc::new(previews),
        jobs,
        access_token: SIGNING_KEY.into(),
        library_id: "photos".into(),
        original_root_names: Default::default(),
    })
}
async fn call(app: axum::Router, method: &str, path: &str, body: Value) -> (StatusCode, Value) {
    let response = app
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {SIGNING_KEY}"))
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}
fn seed(state: &AppState, root: &Path, name: &str) -> String {
    let path = root.join("originals").join(name);
    std::fs::write(&path, b"original bytes").unwrap();
    let snapshot = json!({"captureTime":"2024-01-01T00:00:00.000Z","cameraMake":"Canon","cameraModel":"R3","lensModel":"50mm",
        "originalFilename":name,"contentFingerprint":name,"metadataFingerprint":format!("metadata-{name}"),"rating":1,"flagState":"unflagged","tags":[],
        "createdAt":"2024-01-01T00:00:00.000Z","updatedAt":"2024-01-01T00:00:00.000Z"});
    state
        .store
        .ingest_original(
            "photos",
            path.to_str().unwrap(),
            &json!({"contentHash":name,"sizeBytes":14,"role":"jpeg_original"}),
            &snapshot,
        )
        .unwrap()
}

#[tokio::test]
async fn nas_catalog_commands_queries_authentication_and_restart() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let id = seed(&state, dir.path(), "photo.jpg");
    seed(&state, dir.path(), "second.jpg");
    let app = router(state.clone());
    let unauthenticated = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/libraries/photos/assets")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(unauthenticated.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        call(app.clone(), "GET", "/healthz", Value::Null).await.0,
        StatusCode::OK
    );
    let (status, page) = call(
        app.clone(),
        "GET",
        "/libraries/photos/assets?limit=1",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{page}");
    assert_eq!(page["total"], 2);
    assert_eq!(page["items"].as_array().unwrap().len(), 1);
    assert_eq!(
        page["items"][0]["paths"],
        json!([dir
            .path()
            .join("originals")
            .join(page["items"][0]["originalFilename"].as_str().unwrap())])
    );
    let cursor = page["nextCursor"].as_str().unwrap();
    assert!(cursor.starts_with("cd1."));
    let (status, next) = call(
        app.clone(),
        "GET",
        &format!("/libraries/photos/assets?limit=1&cursor={cursor}"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{next}");
    assert_eq!(next["items"].as_array().unwrap().len(), 1);
    assert_ne!(next["items"][0]["id"], page["items"][0]["id"]);
    assert!(next["nextCursor"].is_null());
    let path = format!("/libraries/photos/assets/{}", id.to_uppercase());
    let patch =
        json!({"rating":5,"flagState":"picked","colorLabel":"green","tags":["旅行","family"]});
    let (status, updated) = call(app.clone(), "PATCH", &path, patch.clone()).await;
    assert_eq!(status, StatusCode::OK, "{updated}");
    assert_eq!(updated["rating"], 5);
    assert_eq!(updated["flagState"], "picked");
    let (_, filtered) = call(
        app.clone(),
        "GET",
        "/libraries/photos/assets?minRating=5&tag=family",
        Value::Null,
    )
    .await;
    assert_eq!(filtered["total"], 1);
    assert_eq!(filtered["items"][0]["id"], id);
    let (_, counts) = call(app.clone(), "GET", "/libraries/photos/counts", Value::Null).await;
    assert_eq!(counts, json!({"all":2,"trashed":0,"picked":1}));
    assert_eq!(
        call(app.clone(), "PATCH", &path, json!({"rating":6}))
            .await
            .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        call(
            app.clone(),
            "PATCH",
            &path,
            json!({"originalFilename":"moved.jpg"})
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        call(app.clone(), "POST", &format!("{path}/trash"), Value::Null)
            .await
            .1["trashed"],
        true
    );
    assert_eq!(
        call(
            app.clone(),
            "GET",
            "/libraries/photos/assets?trashed=true",
            Value::Null
        )
        .await
        .1["total"],
        1
    );
    assert_eq!(
        call(app.clone(), "POST", &format!("{path}/restore"), Value::Null)
            .await
            .1["trashed"],
        false
    );
    assert_eq!(
        call(app.clone(), "PATCH", &path, json!({"colorLabel":null}))
            .await
            .1["colorLabel"],
        Value::Null
    );
    assert_eq!(
        call(
            app.clone(),
            "GET",
            "/libraries/photos/assets?cursor=bad",
            Value::Null
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        std::fs::read(dir.path().join("originals/photo.jpg")).unwrap(),
        b"original bytes"
    );
    drop(app);
    drop(state);
    let reopened = router(self::state(dir.path()));
    let (status, asset) = call(reopened, "GET", &path, Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(asset["rating"], 5);
    assert_eq!(asset["tags"], json!(["family", "旅行"]));
}

#[tokio::test]
async fn client_cannot_upload_ledger_originals_or_derivatives() {
    let dir = tempfile::tempdir().unwrap();
    let app = router(state(dir.path()));
    for path in [
        "/libraries/photos/ops",
        "/devices/mac/heartbeat",
        "/derivatives/uploads",
        "/archive/receipts",
    ] {
        let status = call(app.clone(), "POST", path, json!({})).await.0;
        assert!(
            matches!(
                status,
                StatusCode::NOT_FOUND | StatusCode::METHOD_NOT_ALLOWED
            ),
            "{path}: {status}"
        );
    }
    assert_eq!(
        call(app, "PUT", "/derivatives/local-upload/anything", json!({}))
            .await
            .0,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn folders_jobs_are_library_scoped_and_removal_keeps_originals() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    seed(&state, dir.path(), "photo.jpg");
    let app = router(state.clone());
    let (status, folder) = call(
        app.clone(),
        "POST",
        "/libraries/photos/folders",
        json!({"path":"."}),
    )
    .await;
    assert!(status.is_success(), "{folder}");
    assert_eq!(folder["libraryID"], "photos");
    let id = folder["id"].as_str().unwrap();
    let (_, folders) = call(app.clone(), "GET", "/libraries/photos/folders", Value::Null).await;
    assert_eq!(folders["folders"][0]["id"], id);
    assert!(folders["rootPath"].as_str().unwrap().ends_with("originals"));
    let (status, scan) = call(
        app.clone(),
        "POST",
        &format!("/libraries/photos/folders/{id}/scan"),
        Value::Null,
    )
    .await;
    assert!(status.is_success(), "{scan}");
    assert_eq!(scan["folderID"], id);
    assert_eq!(scan["libraryID"], "photos");
    let (_, jobs) = call(app.clone(), "GET", "/libraries/photos/jobs", Value::Null).await;
    assert_eq!(jobs["jobs"][0]["id"], scan["id"]);
    assert_eq!(
        call(app.clone(), "GET", "/libraries/other/jobs", Value::Null)
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        call(
            app.clone(),
            "DELETE",
            &format!("/libraries/other/folders/{id}"),
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let (status, _) = call(
        app.clone(),
        "DELETE",
        &format!("/libraries/photos/folders/{id}"),
        Value::Null,
    )
    .await;
    assert!(status.is_success());
    assert_eq!(state.jobs.jobs(1).unwrap()[0].status, "cancelled");
    assert_eq!(
        std::fs::read(dir.path().join("originals/photo.jpg")).unwrap(),
        b"original bytes"
    );
}

#[tokio::test]
async fn nas_generated_preview_is_downloaded_by_signed_url() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let id = seed(&state, dir.path(), "photo.jpg");
    let generated = dir.path().join("generated.heic");
    std::fs::write(&generated, b"abc").unwrap();
    let object = state
        .previews
        .put_generated("photos", &id, "preview-hash", &generated)
        .unwrap();
    state.store.declare_generated_preview("photos",&id,&json!({"assetID":id,"role":"preview","fileObject":{"contentHash":"preview-hash","sizeBytes":3,"role":"preview"},"objectRef":object,"pixelSize":{"width":1200,"height":800}})).unwrap();
    let app = router(state);
    let (status, asset) = call(
        app.clone(),
        "GET",
        &format!("/libraries/photos/assets/{id}"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{asset}");
    assert_eq!(asset["preview"]["width"], 1200);
    assert_eq!(asset["preview"]["version"], "preview-hash");
    let (status, metadata) = call(
        app.clone(),
        "GET",
        &format!(
            "/derivatives/{}?role=preview&libraryID=photos",
            id.to_uppercase()
        ),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{metadata}");
    assert_eq!(metadata["width"], asset["preview"]["width"]);
    assert_eq!(metadata["height"], asset["preview"]["height"]);
    assert_eq!(metadata["version"], asset["preview"]["version"]);
    let path = metadata["downloadURL"]
        .as_str()
        .unwrap()
        .strip_prefix("http://localhost")
        .unwrap();
    let response = app
        .clone()
        .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.into_body().collect().await.unwrap().to_bytes(),
        "abc"
    );
    let bad = format!("{path}tampered");
    assert_eq!(
        call(app, "GET", &bad, Value::Null).await.0,
        StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn navigation_lists_empty_and_intermediate_directories_without_indexed_assets() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let root = state.jobs.root();
    for name in ["empty", "middle/leaf", ".hidden", "@eaDir", "#recycle"] {
        std::fs::create_dir_all(root.join(name)).unwrap();
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(root.join("middle"), root.join("linked")).unwrap();
    state
        .jobs
        .add_folder("photos", root.to_str().unwrap())
        .unwrap();
    let app = router(state.clone());
    let (status, page) = call(
        app.clone(),
        "GET",
        "/libraries/photos/navigation",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{page}");
    assert!(page.get("location").is_none());
    assert!(page.get("local").is_none());
    assert!(page["path"].is_null());
    assert_eq!(page["directories"].as_array().unwrap().len(), 2);
    assert_eq!(page["directories"][0]["name"], "empty");
    assert_eq!(page["directories"][0]["hasChildren"], false);
    assert_eq!(page["directories"][1]["name"], "middle");
    assert_eq!(page["directories"][1]["hasChildren"], true);
    let query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("path", root.join("middle").to_str().unwrap())
        .finish();
    let (status, page) = call(
        app,
        "GET",
        &format!("/libraries/photos/navigation?{query}"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["directories"][0]["name"], "leaf");
}

#[tokio::test]
async fn navigation_enforces_active_library_roots_and_rejects_escape_and_symlinks() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let root = state.jobs.root();
    for name in ["a/nested", "b", "inactive"] {
        std::fs::create_dir_all(root.join(name)).unwrap();
    }
    state
        .jobs
        .add_folder("photos", root.join("a").to_str().unwrap())
        .unwrap();
    state
        .jobs
        .add_folder("photos", root.join("a/nested").to_str().unwrap())
        .unwrap();
    state
        .jobs
        .add_folder("other", root.join("b").to_str().unwrap())
        .unwrap();
    let inactive = state
        .jobs
        .add_folder("photos", root.join("inactive").to_str().unwrap())
        .unwrap();
    state.jobs.remove_folder(&inactive.id).unwrap();
    let app = router(state.clone());
    let (_, page) = call(
        app.clone(),
        "GET",
        "/libraries/photos/navigation",
        Value::Null,
    )
    .await;
    assert_eq!(page["directories"].as_array().unwrap().len(), 1);
    assert_eq!(page["directories"][0]["name"], "a");
    let (status, page) = call(
        app.clone(),
        "GET",
        "/libraries/unknown/navigation",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(page["detail"]["code"], "library_not_found");
    let mut denied = vec![
        (root.to_path_buf(), StatusCode::NOT_FOUND),
        (root.join("b"), StatusCode::NOT_FOUND),
        (root.join("inactive"), StatusCode::NOT_FOUND),
        (root.join("a/../b"), StatusCode::UNPROCESSABLE_ENTITY),
        (dir.path().to_path_buf(), StatusCode::UNPROCESSABLE_ENTITY),
    ];
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(root.join("b"), root.join("a/link")).unwrap();
        denied.push((root.join("a/link"), StatusCode::UNPROCESSABLE_ENTITY));
    }
    for (path, expected) in denied {
        let query = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("path", path.to_str().unwrap())
            .finish();
        let (status, body) = call(
            app.clone(),
            "GET",
            &format!("/libraries/photos/navigation?{query}"),
            Value::Null,
        )
        .await;
        assert_eq!(status, expected, "{}: {body}", path.display());
    }
}

#[tokio::test]
async fn navigation_photo_counts_are_distinct_recursive_live_catalog_counts() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let root = state.jobs.root();
    for name in ["foo/年份", "Foo", "foobar", "empty", "旅行_%"] {
        std::fs::create_dir_all(root.join(name)).unwrap();
    }
    state
        .jobs
        .add_folder("photos", root.to_str().unwrap())
        .unwrap();
    let first = seed(&state, dir.path(), "first.jpg");
    let second = seed(&state, dir.path(), "second.jpg");
    let trashed = seed(&state, dir.path(), "trashed.jpg");
    state.store.set_trashed("photos", &trashed, true).unwrap();
    let db = rusqlite::Connection::open(dir.path().join("keeps/db/control_plane.sqlite")).unwrap();
    for (relative, asset) in [
        ("foo/first.jpg", &first),
        ("foo/年份/duplicate.jpg", &first),
        ("foo/年份/second.jpg", &second),
        ("foo/trashed.jpg", &trashed),
        ("foobar/first.jpg", &first),
        ("Foo/second.jpg", &second),
        ("旅行_%/second.jpg", &second),
    ] {
        db.execute("INSERT INTO catalog_paths(library_id,path,asset_id,content_hash,role) VALUES('photos',?1,?2,'fixture','jpeg_original')", rusqlite::params![root.join(relative).to_str().unwrap(), asset]).unwrap();
    }
    let app = router(state.clone());
    let (status, page) = call(
        app.clone(),
        "GET",
        "/libraries/photos/navigation",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{page}");
    for directory in page["directories"].as_array().unwrap() {
        let expected = match directory["name"].as_str().unwrap() {
            "foo" => 2,
            "Foo" | "foobar" | "旅行_%" => 1,
            "empty" => 0,
            name => panic!("unexpected {name}"),
        };
        assert_eq!(directory["photoCount"], expected, "{directory}");
        let query = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("directory", directory["path"].as_str().unwrap())
            .finish();
        let (status, gallery) = call(
            app.clone(),
            "GET",
            &format!("/libraries/photos/assets?{query}"),
            Value::Null,
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{gallery}");
        assert_eq!(directory["photoCount"], gallery["total"]);
    }
    let direct_query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("directory", root.join("foo").to_str().unwrap())
        .append_pair("recursive", "false")
        .finish();
    let (status, direct) = call(
        app,
        "GET",
        &format!("/libraries/photos/assets?{direct_query}"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(direct["total"], 1);
    let other = state
        .store
        .directory_photo_counts("other", &[root.join("foo").to_string_lossy().into_owned()])
        .unwrap();
    assert_eq!(other, vec![0]);
}

#[tokio::test]
async fn hidden_directories_filter_before_paging_and_persist() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    for folder in ["private/nested", "private-other", "public"] {
        std::fs::create_dir_all(dir.path().join("originals").join(folder)).unwrap();
    }
    let root = dir.path().join("originals");
    let hidden = root.join("private").to_str().unwrap().to_string();
    let nested = format!("{hidden}/nested");
    let id = seed(&state, dir.path(), "private/a.jpg");
    seed(&state, dir.path(), "private/nested/b.jpg");
    seed(&state, dir.path(), "private-other/c.jpg");
    seed(&state, dir.path(), "public/d.jpg");
    state
        .store
        .patch_asset("photos", &id, &json!({"flagState":"picked"}))
        .unwrap();
    let app = router(state.clone());
    let endpoint = "/libraries/photos/hidden-directories";
    for path in [&hidden, &nested] {
        let (status, response) = call(
            app.clone(),
            "PUT",
            endpoint,
            json!({"path":path,"hidden":true}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(response["paths"].as_array().unwrap().contains(&json!(path)));
    }
    let (_, page) = call(
        app.clone(),
        "GET",
        "/libraries/photos/assets?limit=1",
        Value::Null,
    )
    .await;
    assert_eq!(page["total"], 2);
    let cursor = page["nextCursor"].as_str().unwrap();
    assert!(cursor.starts_with("cd1."));
    let (status, next) = call(
        app.clone(),
        "GET",
        &format!("/libraries/photos/assets?limit=1&cursor={cursor}"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{next}");
    assert_eq!(next["items"].as_array().unwrap().len(), 1);
    assert_ne!(next["items"][0]["id"], page["items"][0]["id"]);
    assert!(next["nextCursor"].is_null());
    let (_, counts) = call(app.clone(), "GET", "/libraries/photos/counts", Value::Null).await;
    assert_eq!(counts, json!({"all":2,"picked":0,"trashed":0}));
    let (_, counts) = call(
        app.clone(),
        "GET",
        "/libraries/photos/counts?showHidden=true",
        Value::Null,
    )
    .await;
    assert_eq!(counts["all"], 4);
    let (_, all) = call(
        app.clone(),
        "GET",
        "/libraries/photos/assets?showHidden=true",
        Value::Null,
    )
    .await;
    assert_eq!(all["total"], 4);
    let query = |path: &str| {
        format!(
            "/libraries/photos/assets?directory={}",
            url::form_urlencoded::byte_serialize(path.as_bytes()).collect::<String>()
        )
    };
    for path in [&hidden, &nested] {
        let (_, page) = call(app.clone(), "GET", &query(path), Value::Null).await;
        assert_eq!(page["total"], 1);
    }
    let (_, page) = call(
        app.clone(),
        "GET",
        "/libraries/photos/assets?q=a.jpg",
        Value::Null,
    )
    .await;
    assert_eq!(page["total"], 0);
    state.store.set_trashed("photos", &id, true).unwrap();
    let (_, page) = call(
        app.clone(),
        "GET",
        "/libraries/photos/assets?trashed=true",
        Value::Null,
    )
    .await;
    assert_eq!(page["total"], 0);
    assert_eq!(
        call(
            app.clone(),
            "PUT",
            endpoint,
            json!({"path":"relative","hidden":true})
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    let (_, response) = call(
        app.clone(),
        "PUT",
        endpoint,
        json!({"path":hidden,"hidden":false}),
    )
    .await;
    assert_eq!(response, json!({"paths":[nested]}));
    drop(app);
    drop(state);
    let store = Store::open(&dir.path().join("keeps/db/control_plane.sqlite"), false).unwrap();
    assert_eq!(
        store.hidden_directories("photos").unwrap(),
        json!({"paths":[nested]})
    );
    assert_eq!(
        store.hidden_directories("another").unwrap(),
        json!({"paths":[]})
    );
}

#[tokio::test]
async fn version_api_requires_asset_membership_and_exposes_revision() {
    let dir = tempfile::tempdir().unwrap();
    let canonical = dir.path().canonicalize().unwrap();
    let state = state(&canonical);
    let id = seed(&state, &canonical, "one.jpg");
    let other = seed(&state, &canonical, "two.jpg");
    let folder = state.jobs.add_folder("photos", ".").unwrap();
    let app = router(state.clone());
    let route = format!("/libraries/photos/assets/{id}");
    let before = call(
        app.clone(),
        "GET",
        "/libraries/photos/revision",
        Value::Null,
    )
    .await
    .1["revision"]
        .as_i64()
        .unwrap();
    let (status, versions) = call(
        app.clone(),
        "GET",
        &format!("{route}/versions"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(versions["items"][0]["contentHash"], "one.jpg");
    assert_eq!(versions["items"][0]["isDefault"], true);
    assert_eq!(
        call(
            app.clone(),
            "PUT",
            &format!("{route}/default-version"),
            json!({"contentHash":"two.jpg"})
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    let (status, versions) = call(
        app.clone(),
        "PUT",
        &format!("{route}/default-version"),
        json!({"contentHash":"one.jpg"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(versions["items"][0]["userSelected"], true);
    assert!(
        call(
            app.clone(),
            "GET",
            "/libraries/photos/revision",
            Value::Null
        )
        .await
        .1["revision"]
            .as_i64()
            .unwrap()
            > before
    );
    state.jobs.remove_folder(&folder.id).unwrap();
    let revision_before = state.store.library_revision("photos").unwrap();
    assert_eq!(
        call(
            app.clone(),
            "PUT",
            &format!("{route}/default-version"),
            json!({"contentHash":"one.jpg"})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        state.store.library_revision("photos").unwrap(),
        revision_before
    );
    let candidates = call(
        app,
        "GET",
        &format!("{route}/version-candidates"),
        Value::Null,
    )
    .await
    .1;
    assert_eq!(candidates["items"][0]["assetID"], other);
    assert_eq!(
        std::fs::read(dir.path().join("originals/one.jpg")).unwrap(),
        b"original bytes"
    );
}

#[tokio::test]
async fn rejects_unknown_library_but_accepts_configured_empty_library() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let app = router(state.clone());
    for endpoint in [
        "counts",
        "assets",
        "revision",
        "directories",
        "navigation",
        "folders",
        "jobs",
        "hidden-directories",
    ] {
        let (status, body) = call(
            app.clone(),
            "GET",
            &format!("/libraries/hechuan/{endpoint}"),
            Value::Null,
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{endpoint}: {body}");
        assert_eq!(body["detail"]["code"], "library_not_found");
        let (status, body) = call(
            app.clone(),
            "GET",
            &format!("/libraries/photos/{endpoint}"),
            Value::Null,
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{endpoint}: {body}");
    }
    let (status, body) = call(
        app.clone(),
        "POST",
        "/libraries/hechuan/folders",
        json!({"path":"."}),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    assert!(state.jobs.folders().unwrap().is_empty());
}

#[tokio::test]
async fn unknown_library_preview_metadata_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let app = router(state(dir.path()));
    let (status, body) = call(
        app,
        "GET",
        "/derivatives/00000000-0000-0000-0000-000000000001?role=preview&libraryID=hechuan",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["detail"]["code"], "library_not_found");
}

#[tokio::test]
async fn catalog_revision_api_tracks_changed_branches_and_preserves_default_contract() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let root = dir.path().join("originals");
    std::fs::create_dir_all(root.join("2026/summer")).unwrap();
    std::fs::create_dir_all(root.join("2025")).unwrap();
    let id = seed(&state, dir.path(), "2026/summer/one.jpg");
    seed(&state, dir.path(), "2025/two.jpg");
    let app = router(state.clone());
    let revision_route = |path: &Path, children: bool| {
        let query = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("path", path.to_str().unwrap())
            .append_pair("includeChildren", if children { "true" } else { "false" })
            .finish();
        format!("/libraries/photos/revision?{query}")
    };
    let (status, before) = call(
        app.clone(),
        "GET",
        "/libraries/photos/revision",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(before["isUpdating"], false);
    assert!(before["revision"].as_i64().unwrap() > 0);
    let sibling_route = revision_route(&root.join("2025"), false);
    let sibling_before = call(app.clone(), "GET", &sibling_route, Value::Null)
        .await
        .1;
    let (status, updated) = call(
        app.clone(),
        "PATCH",
        &format!("/libraries/photos/assets/{id}"),
        json!({"rating":5}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{updated}");
    let after = call(
        app.clone(),
        "GET",
        "/libraries/photos/revision",
        Value::Null,
    )
    .await
    .1;
    assert!(after["revision"].as_i64().unwrap() > before["revision"].as_i64().unwrap());
    for path in [&root, &root.join("2026"), &root.join("2026/summer")] {
        let (status, branch) = call(
            app.clone(),
            "GET",
            &revision_route(path, false),
            Value::Null,
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{branch}");
        assert_eq!(
            branch,
            json!({"path":path,"revision":after["revision"],"isUpdating":false})
        );
    }
    assert_eq!(
        call(app.clone(), "GET", &sibling_route, Value::Null)
            .await
            .1,
        sibling_before
    );
    let (status, tree) = call(
        app.clone(),
        "GET",
        &revision_route(&root, true),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{tree}");
    assert_eq!(
        tree["children"],
        json!([
            {"path":root.join("2025"),"revision":sibling_before["revision"],"isUpdating":false},
            {"path":root.join("2026"),"revision":after["revision"],"isUpdating":false},
        ])
    );
    let (status, root_tree) = call(
        app.clone(),
        "GET",
        "/libraries/photos/revision?includeChildren=true",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{root_tree}");
    assert_eq!(root_tree["revision"], after["revision"]);
    assert!(root_tree["children"].is_array());
    let directory_query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("directory", root.join("2026").to_str().unwrap())
        .finish();
    let (status, assets) = call(
        app.clone(),
        "GET",
        &format!("/libraries/photos/assets?{directory_query}"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{assets}");
    assert_eq!(assets["revision"], after["revision"]);
    assert_eq!(assets["isUpdating"], false);
    assert_eq!(assets["items"][0]["rating"], 5);
    let (status, empty) = call(
        app.clone(),
        "GET",
        &revision_route(&root.join("not-on-disk"), false),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{empty}");
    assert_eq!(empty["revision"], 0);
    let response = app
        .oneshot(
            Request::builder()
                .uri("/libraries/photos/revision?includeChildren=true")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn catalog_revision_api_exposes_batch_activity_by_scope_until_completion() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let root = dir.path().join("originals");
    for name in ["first", "second"] {
        std::fs::create_dir_all(root.join(name)).unwrap();
        seed(&state, dir.path(), &format!("{name}/photo.jpg"));
    }
    let app = router(state.clone());
    let route = |key: &str, path: &Path| {
        let query = url::form_urlencoded::Serializer::new(String::new())
            .append_pair(key, path.to_str().unwrap())
            .append_pair("includeChildren", "true")
            .finish();
        format!(
            "/libraries/photos/{}?{query}",
            if key == "path" { "revision" } else { "assets" }
        )
    };
    let first = root.join("first");
    let second = root.join("second");
    let before = call(app.clone(), "GET", &route("path", &root), Value::Null)
        .await
        .1;
    state
        .store
        .note_revision_activity("photos", "batch", first.to_str().unwrap())
        .unwrap();
    let active = call(app.clone(), "GET", &route("path", &root), Value::Null)
        .await
        .1;
    assert_eq!(active["isUpdating"], true);
    assert!(active["revision"].as_i64() > before["revision"].as_i64());
    assert_eq!(active["children"][0]["path"], json!(first));
    assert_eq!(active["children"][0]["isUpdating"], true);
    assert_eq!(active["children"][1]["path"], json!(second));
    assert_eq!(active["children"][1]["isUpdating"], false);
    for (path, updating) in [(&first, true), (&second, false)] {
        let (status, page) = call(app.clone(), "GET", &route("directory", path), Value::Null).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(page["isUpdating"], updating);
    }
    let library_active = call(
        app.clone(),
        "GET",
        "/libraries/photos/revision",
        Value::Null,
    )
    .await
    .1;
    assert_eq!(library_active["isUpdating"], true);
    state
        .store
        .note_revision_activity("photos", "batch", second.to_str().unwrap())
        .unwrap();
    let expanded = call(app.clone(), "GET", &route("path", &root), Value::Null)
        .await
        .1;
    assert_eq!(expanded["revision"], active["revision"]);
    assert_eq!(expanded["children"][0], active["children"][0]);
    assert_eq!(expanded["children"][1]["isUpdating"], true);
    assert!(
        expanded["children"][1]["revision"].as_i64() > active["children"][1]["revision"].as_i64()
    );
    assert_eq!(
        call(
            app.clone(),
            "GET",
            "/libraries/photos/revision",
            Value::Null
        )
        .await
        .1,
        library_active
    );
    state.store.finish_revision_batch("batch", false).unwrap();
    let stable = call(app.clone(), "GET", &route("path", &root), Value::Null)
        .await
        .1;
    assert_eq!(stable["isUpdating"], false);
    assert!(stable["revision"].as_i64() > expanded["revision"].as_i64());
    for (index, path) in [&first, &second].iter().enumerate() {
        assert_eq!(stable["children"][index]["isUpdating"], false);
        assert!(
            stable["children"][index]["revision"].as_i64()
                > expanded["children"][index]["revision"].as_i64()
        );
        assert_eq!(
            call(app.clone(), "GET", &route("directory", path), Value::Null)
                .await
                .1["isUpdating"],
            false
        );
    }
    let library_stable = call(app, "GET", "/libraries/photos/revision", Value::Null)
        .await
        .1;
    assert_eq!(library_stable["isUpdating"], false);
    assert!(library_stable["revision"].as_i64() > library_active["revision"].as_i64());
}

#[tokio::test]
async fn catalog_revision_api_rejects_invalid_paths() {
    let dir = tempfile::tempdir().unwrap();
    let app = router(state(dir.path()));
    for path in ["relative", "/photos/../other", "", "/photos\0bad"] {
        let query = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("path", path)
            .finish();
        let (status, body) = call(
            app.clone(),
            "GET",
            &format!("/libraries/photos/revision?{query}"),
            Value::Null,
        )
        .await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{path:?}: {body}");
    }
    let (status, body) = call(
        app,
        "GET",
        "/libraries/unknown/revision?includeChildren=true",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
}

#[tokio::test]
async fn cache_status_and_role_signed_streaming_preserve_original_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let id = seed(&state, dir.path(), "standard.jpg");
    state.store.reconcile_cache().unwrap();
    let source = dir.path().join("originals/standard.jpg");
    let generated = dir.path().join("thumb.heic");
    std::fs::write(&generated, b"small thumbnail").unwrap();
    let object = state
        .previews
        .put_generated("photos", &id, "thumbnail-hash", &generated)
        .unwrap();
    let db = rusqlite::Connection::open(dir.path().join("keeps/db/control_plane.sqlite")).unwrap();
    let thumb =
        json!({"objectRef":object,"width":512,"height":384,"version":"spec:thumbnail-hash"});
    let standard = json!({"path":source,"width":4000,"height":3000,"version":"standard.jpg","sizeBytes":14,"mtimeNs":keeps_server::cache_pipeline::file_mtime(&source).unwrap()});
    db.execute(
        "UPDATE media_cache SET status='ready',thumbnail=?,standard=?",
        rusqlite::params![thumb.to_string(), standard.to_string()],
    )
    .unwrap();
    let app = router(state.clone());
    let (status, asset) = call(
        app.clone(),
        "GET",
        &format!("/libraries/photos/assets/{id}"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(asset["thumbnail"]["width"], 512);
    assert_eq!(asset["standard"]["width"], 4000);
    let (status, descriptor) = call(
        app.clone(),
        "GET",
        &format!("/derivatives/{id}?role=standard&libraryID=photos"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let url = url::Url::parse(descriptor["downloadURL"].as_str().unwrap()).unwrap();
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(url.path())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["content-type"], "image/jpeg");
    assert_eq!(
        response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .as_ref(),
        b"original bytes"
    );
    let (status, progress) = call(
        app.clone(),
        "GET",
        "/libraries/photos/cache-status",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(progress["counts"]["ready"], 1);
    assert_eq!(
        call(
            app.clone(),
            "GET",
            "/libraries/other/cache-status",
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let mut bad = url.path().to_owned();
    bad.push('x');
    assert_ne!(
        app.oneshot(Request::builder().uri(bad).body(Body::empty()).unwrap())
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    assert_eq!(std::fs::read(source).unwrap(), b"original bytes");
}

#[tokio::test]
async fn video_cover_never_exposes_video_as_standard_photo() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let id = seed(&state, dir.path(), "movie.mov");
    state.store.reconcile_cache().unwrap();
    let path = dir.path().join("originals/movie.mov");
    let cover = dir.path().join("cover.heic");
    std::fs::write(&cover, b"cover").unwrap();
    let object = state
        .previews
        .put_generated_role("photos", &id, "cover", &cover, "thumbnail")
        .unwrap();
    let db = rusqlite::Connection::open(dir.path().join("keeps/db/control_plane.sqlite")).unwrap();
    db.execute(
        "UPDATE media_cache SET status='ready',thumbnail=?,standard=?",
        rusqlite::params![
            json!({"objectRef":object,"width":512,"height":288,"version":"cover"}).to_string(),
            json!({"path":path,"width":1920,"height":1080,"version":"movie.mov"}).to_string()
        ],
    )
    .unwrap();
    assert_eq!(
        db.query_row("SELECT count(*) FROM videos", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    let app = router(state);
    let (status, asset) = call(
        app.clone(),
        "GET",
        &format!("/libraries/photos/assets/{id}"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(asset["standard"].is_null());
    assert!(!asset["thumbnail"].is_null());
    assert_eq!(
        call(
            app,
            "GET",
            &format!("/derivatives/{id}?role=standard"),
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn deferred_3fr_keeps_thumbnail_without_raw_standard_link() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let id = seed(&state, dir.path(), "capture.3fr");
    state.store.reconcile_cache().unwrap();
    let path = dir.path().join("originals/capture.3fr");
    let cover = dir.path().join("cover.heic");
    std::fs::write(&cover, b"cover").unwrap();
    let object = state
        .previews
        .put_generated_role("photos", &id, "cover", &cover, "thumbnail")
        .unwrap();
    let db = rusqlite::Connection::open(dir.path().join("keeps/db/control_plane.sqlite")).unwrap();
    db.execute(
        "UPDATE media_cache SET status='ready',thumbnail=?,standard=?",
        rusqlite::params![
            json!({"objectRef":object,"width":512,"height":288,"version":"cover"}).to_string(),
            json!({"path":path,"width":1920,"height":1080,"version":"capture.3fr","deferred":true})
                .to_string()
        ],
    )
    .unwrap();
    assert_eq!(
        db.query_row("SELECT count(*) FROM photos", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    let app = router(state);
    let (status, asset) = call(
        app.clone(),
        "GET",
        &format!("/libraries/photos/assets/{id}"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(asset["standard"].is_null());
    assert!(!asset["thumbnail"].is_null());
    assert_eq!(
        call(
            app,
            "GET",
            &format!("/derivatives/{id}?role=standard"),
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn imports_flatten_grouped_files_verify_and_publish_only_on_finish() {
    use sha2::{Digest, Sha256};
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    state.jobs.add_folder("photos", ".").unwrap();
    let root = state.jobs.root().to_path_buf();
    std::fs::write(root.join("IMG.CR3"), b"existing").unwrap();
    let app = router(state.clone());
    let batch = uuid::Uuid::new_v4().to_string().to_uppercase();
    let paths = [
        "card1/IMG.CR3",
        "card1/IMG.CR3.xmp",
        "card1/IMG.heic",
        "card2/IMG.CR3",
        "card2/IMG.xmp",
        "card3/nested/IMG.JPG",
        "card3/nested/IMG.JPG.xmp",
        "card4/nested/IMG.JpEg",
    ];
    let data = b"imported original";
    let files:Vec<Value>=paths.iter().map(|p|json!({"id":uuid::Uuid::new_v4().to_string().to_uppercase(),"relativePath":p,"size":data.len(),"sha256":format!("{:x}",Sha256::digest(data))})).collect();
    let manifest = json!({"id":batch,"targetPath":root,"files":files});
    let (status, prepared) = call(
        app.clone(),
        "POST",
        "/libraries/photos/imports",
        manifest.clone(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{prepared}");
    let names: Vec<_> = prepared["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["fileName"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        vec![
            "IMG (1).CR3",
            "IMG (1).CR3.xmp",
            "IMG (1).heic",
            "IMG (2).CR3",
            "IMG (2).xmp",
            "IMG (3).JPG",
            "IMG (3).JPG.xmp",
            "IMG (4).JpEg"
        ]
    );
    let finish_url = format!("/libraries/photos/imports/{batch}/finish");
    assert_eq!(
        call(app.clone(), "POST", &finish_url, Value::Null).await.0,
        StatusCode::CONFLICT
    );
    for (index, file) in files.iter().enumerate() {
        let url = format!(
            "/libraries/photos/imports/{batch}/files/{}",
            file["id"].as_str().unwrap()
        );
        if index == 0 {
            for wrong in [
                b"short".as_slice(),
                b"corrupted content".as_slice(),
                b"longer than declared data".as_slice(),
            ] {
                let response = app
                    .clone()
                    .oneshot(
                        Request::builder()
                            .method("PUT")
                            .uri(&url)
                            .header("authorization", format!("Bearer {SIGNING_KEY}"))
                            .body(Body::from(wrong))
                            .unwrap(),
                    )
                    .await
                    .unwrap();
                assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
                assert!(!root.join(names[index]).exists());
            }
        }
        for _ in 0..2 {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("PUT")
                        .uri(&url)
                        .header("authorization", format!("Bearer {SIGNING_KEY}"))
                        .body(Body::from(data.as_slice()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
        }
        assert!(
            !root.join(names[index]).exists(),
            "original published before finish"
        );
    }
    let resumed = call(
        app.clone(),
        "POST",
        "/libraries/photos/imports",
        manifest.clone(),
    )
    .await
    .1;
    assert!(
        resumed["files"]
            .as_array()
            .unwrap()
            .iter()
            .all(|f| f["uploaded"] == true)
    );
    let completed = call(app.clone(), "POST", &finish_url, Value::Null).await;
    assert_eq!(completed.0, StatusCode::OK, "{}", completed.1);
    let repeated = call(app.clone(), "POST", &finish_url, Value::Null).await;
    assert_eq!(completed.1["job"]["id"], repeated.1["job"]["id"]);
    for name in names {
        assert_eq!(std::fs::read(root.join(name)).unwrap(), data);
    }
    assert_eq!(std::fs::read(root.join("IMG.CR3")).unwrap(), b"existing");
    let mut changed = manifest.clone();
    changed["files"][0]["relativePath"] = json!("changed.CR3");
    assert_eq!(
        call(app.clone(), "POST", "/libraries/photos/imports", changed)
            .await
            .0,
        StatusCode::CONFLICT
    );
    let reopened = Jobs::open(&dir.path().join("keeps/db/jobs.sqlite"), &root).unwrap();
    assert!(
        reopened
            .job(completed.1["job"]["id"].as_str().unwrap())
            .unwrap()
            .is_some()
    );
}

#[tokio::test]
async fn imports_reject_escape_symlinks_untracked_targets_and_preserve_late_collision() {
    use sha2::{Digest, Sha256};
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let root = state.jobs.root().to_path_buf();
    let app = router(state.clone());
    let batch = uuid::Uuid::new_v4().to_string();
    let file = uuid::Uuid::new_v4().to_string();
    let data = b"new raw";
    let manifest = json!({"id":batch,"targetPath":root,"files":[{"id":file,"relativePath":"sub/IMG.RAW","size":data.len(),"sha256":format!("{:x}",Sha256::digest(data))}]});
    assert_eq!(
        call(
            app.clone(),
            "POST",
            "/libraries/photos/imports",
            manifest.clone()
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    state.jobs.add_folder("photos", ".").unwrap();
    for source in [
        "../IMG.RAW",
        "/IMG.RAW",
        "sub/../IMG.RAW",
        "IMG.PNG",
        ".RAW",
    ] {
        let mut bad = manifest.clone();
        bad["files"][0]["relativePath"] = json!(source);
        assert_eq!(
            call(app.clone(), "POST", "/libraries/photos/imports", bad)
                .await
                .0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
    }
    std::os::unix::fs::symlink(dir.path(), root.join("escape")).unwrap();
    for destination in [root.join("escape"), dir.path().to_path_buf()] {
        let mut bad = manifest.clone();
        bad["targetPath"] = json!(destination);
        assert_eq!(
            call(app.clone(), "POST", "/libraries/photos/imports", bad)
                .await
                .0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
    }
    assert_eq!(
        call(app.clone(), "POST", "/libraries/photos/imports", manifest)
            .await
            .0,
        StatusCode::OK
    );
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(format!("/libraries/photos/imports/{batch}/files/{file}"))
                .header("authorization", format!("Bearer {SIGNING_KEY}"))
                .body(Body::from(data.as_slice()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    std::fs::write(root.join("IMG.RAW"), b"external original").unwrap();
    assert_eq!(
        call(
            app.clone(),
            "POST",
            &format!("/libraries/photos/imports/{batch}/finish"),
            Value::Null
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        std::fs::read(root.join("IMG.RAW")).unwrap(),
        b"external original"
    );
}

#[tokio::test]
async fn create_directory_selects_visible_child_and_preserves_existing_files() {
    let fixture = tempfile::tempdir().unwrap();
    let state = state(fixture.path());
    state.jobs.add_folder("photos", ".").unwrap();
    let parent = state.jobs.root().to_path_buf();
    let app = router(state);
    let request = json!({"parentPath":parent,"name":"旅行 2026"});
    let (status, created) = call(
        app.clone(),
        "POST",
        "/libraries/photos/directories",
        request.clone(),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    assert_eq!(created["path"], parent.join("旅行 2026").to_str().unwrap());
    assert!(parent.join("旅行 2026").is_dir());
    let (_, navigation) = call(
        app.clone(),
        "GET",
        "/libraries/photos/navigation",
        Value::Null,
    )
    .await;
    assert!(
        navigation["directories"]
            .as_array()
            .unwrap()
            .iter()
            .any(|directory| directory["path"] == created["path"])
    );
    std::fs::write(parent.join("旅行 2026/photo.raw"), b"keep original").unwrap();
    assert_eq!(
        call(
            app.clone(),
            "POST",
            "/libraries/photos/directories",
            request
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        std::fs::read(parent.join("旅行 2026/photo.raw")).unwrap(),
        b"keep original"
    );
    std::fs::write(parent.join("existing.raw"), b"original").unwrap();
    assert_eq!(
        call(
            app,
            "POST",
            "/libraries/photos/directories",
            json!({"parentPath":parent,"name":"existing.raw"})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        std::fs::read(parent.join("existing.raw")).unwrap(),
        b"original"
    );
}

#[tokio::test]
async fn create_directory_rejects_invalid_names_and_untracked_parents() {
    let fixture = tempfile::tempdir().unwrap();
    let state = state(fixture.path());
    let root = state.jobs.root().to_path_buf();
    std::fs::create_dir(root.join("tracked")).unwrap();
    std::fs::create_dir(root.join("other")).unwrap();
    state.jobs.add_folder("photos", "tracked").unwrap();
    state.jobs.add_folder("another-library", "other").unwrap();
    let app = router(state);
    for name in [
        "",
        "  ",
        ".",
        "..",
        ".hidden",
        "@eaDir",
        "#recycle",
        "a/b",
        "a\\b",
        "/absolute",
        "nul\0",
        "tab\t",
        "line\n",
    ] {
        let (status, error) = call(
            app.clone(),
            "POST",
            "/libraries/photos/directories",
            json!({"parentPath":root.join("tracked"),"name":name}),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::UNPROCESSABLE_ENTITY,
            "{name:?}: {error}"
        );
    }
    for parent in [root.clone(), root.join("other")] {
        assert_eq!(
            call(
                app.clone(),
                "POST",
                "/libraries/photos/directories",
                json!({"parentPath":parent,"name":"new"})
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
        assert!(!parent.join("new").exists());
    }
    for parent in [
        fixture.path().to_path_buf(),
        root.join("tracked/../other"),
        root.join("missing"),
    ] {
        assert_eq!(
            call(
                app.clone(),
                "POST",
                "/libraries/photos/directories",
                json!({"parentPath":parent,"name":"new"})
            )
            .await
            .0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
        assert!(!parent.join("new").exists());
    }
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(root.join("other"), root.join("tracked/link")).unwrap();
        assert_eq!(
            call(
                app,
                "POST",
                "/libraries/photos/directories",
                json!({"parentPath":root.join("tracked/link"),"name":"new"})
            )
            .await
            .0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
        assert!(!root.join("other/new").exists());
    }
}

#[tokio::test]
async fn imports_without_client_digest_validate_size_and_resume_staged_upload() {
    use sha2::{Digest, Sha256};
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    state.jobs.add_folder("photos", ".").unwrap();
    let root = state.jobs.root().to_path_buf();
    let app = router(state.clone());
    let batch = uuid::Uuid::new_v4().to_string();
    let file = uuid::Uuid::new_v4().to_string();
    let data = b"streamed original";
    let manifest = json!({"id":batch,"targetPath":root,"files":[{
        "id":file,"relativePath":"card/IMG.CR3","size":data.len()
    }]});
    let (status, prepared) = call(
        app.clone(),
        "POST",
        "/libraries/photos/imports",
        manifest.clone(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{prepared}");
    assert!(prepared["files"][0].get("sha256").is_none());
    let url = format!("/libraries/photos/imports/{batch}/files/{file}");
    for wrong in [
        b"short".as_slice(),
        b"larger than declared original".as_slice(),
    ] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri(&url)
                    .header("authorization", format!("Bearer {SIGNING_KEY}"))
                    .body(Body::from(wrong))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 0);
    }
    // A process may stop after linking the upload but before recording completion.
    let staged = root.join(format!(".keeps-import-{batch}-{file}"));
    std::fs::write(&staged, b"different content").unwrap();
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(&url)
                .header("authorization", format!("Bearer {SIGNING_KEY}"))
                .body(Body::from(data.as_slice()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
    assert_eq!(std::fs::read(&staged).unwrap(), b"different content");
    std::fs::write(&staged, data).unwrap();
    for _ in 0..2 {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri(&url)
                    .header("authorization", format!("Bearer {SIGNING_KEY}"))
                    .body(Body::from(data.as_slice()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }
    let (status, resumed) = call(
        app.clone(),
        "POST",
        "/libraries/photos/imports",
        manifest.clone(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{resumed}");
    assert_eq!(resumed["files"][0]["uploaded"], true);
    assert!(resumed["files"][0].get("sha256").is_none());
    assert_eq!(
        resumed["files"][0]["receivedSha256"],
        format!("{:x}", Sha256::digest(data))
    );
    let completed = call(
        app.clone(),
        "POST",
        &format!("/libraries/photos/imports/{batch}/finish"),
        Value::Null,
    )
    .await;
    assert_eq!(completed.0, StatusCode::OK, "{}", completed.1);
    assert_eq!(std::fs::read(root.join("IMG.CR3")).unwrap(), data);
    assert!(!staged.exists());
}

#[tokio::test]
async fn imports_deduplicate_skips_existing_group_and_rechecks_before_finish() {
    use sha2::{Digest, Sha256};
    for changed in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let state = state(dir.path());
        state.jobs.add_folder("photos", ".").unwrap();
        let root = state.jobs.root().to_path_buf();
        std::fs::write(root.join("existing.CR3"), b"original").unwrap();
        let app = router(state.clone());
        let batch = uuid::Uuid::new_v4().to_string();
        let file = uuid::Uuid::new_v4().to_string();
        let mut manifest = json!({"id":batch,"targetPath":root,"deduplicate":true,"files":[{
            "id":file,"relativePath":"card/IMG.CR3","size":8
        }]});
        assert_eq!(
            call(
                app.clone(),
                "POST",
                "/libraries/photos/imports",
                manifest.clone()
            )
            .await
            .0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
        manifest["files"][0]["sha256"] = json!(format!("{:x}", Sha256::digest(b"original")));
        let (status, prepared) = call(
            app.clone(),
            "POST",
            "/libraries/photos/imports",
            manifest.clone(),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{prepared}");
        assert_eq!(prepared["files"][0]["fileName"], "existing.CR3");
        assert_eq!(prepared["files"][0]["skipped"], true);
        assert_eq!(prepared["files"][0]["uploaded"], true);
        manifest["deduplicate"] = json!(false);
        assert_eq!(
            call(app.clone(), "POST", "/libraries/photos/imports", manifest)
                .await
                .0,
            StatusCode::CONFLICT
        );
        if changed {
            std::fs::write(root.join("existing.CR3"), b"modified").unwrap();
        }
        let finished = call(
            app.clone(),
            "POST",
            &format!("/libraries/photos/imports/{batch}/finish"),
            Value::Null,
        )
        .await;
        assert_eq!(
            finished.0,
            if changed {
                StatusCode::CONFLICT
            } else {
                StatusCode::OK
            },
            "{}",
            finished.1
        );
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 1);
    }
}

#[tokio::test]
async fn task_summary_is_scoped_and_cache_rebuild_queues_manual_photo_work() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let folder = state.jobs.add_folder("photos", ".").unwrap();
    let id = seed(&state, &dir.path().canonicalize().unwrap(), "photo.jpg");
    state.store.reconcile_cache().unwrap();
    let db = rusqlite::Connection::open(dir.path().join("keeps/db/control_plane.sqlite")).unwrap();
    db.execute(
        "UPDATE media_cache SET status='ready',thumbnail='{}',standard='{}'",
        [],
    )
    .unwrap();
    let app = router(state.clone());
    let (status, body) = call(
        app.clone(),
        "GET",
        "/libraries/photos/task-status",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body.as_object().unwrap().len(), 2);
    assert_eq!(body["automatic"]["remainingPhotos"], 0);
    assert_eq!(
        call(
            app.clone(),
            "GET",
            "/libraries/other/task-status",
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let (status, body) = call(
        app.clone(),
        "POST",
        "/libraries/photos/cache-rebuild",
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["requeued"], 1);
    let job = state.jobs.claim_class("manual").unwrap().unwrap();
    assert_eq!(job.folder_id, folder.id);
    assert!(job.refresh_metadata);
    assert_eq!(
        db.query_row(
            "SELECT status FROM media_cache WHERE asset_id=?",
            [id],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        "ready"
    );
    let (_, summary) = call(app, "GET", "/libraries/photos/task-status", Value::Null).await;
    assert_eq!(summary["longTask"]["kind"], "manual");
    assert_eq!(summary["automatic"]["remainingPhotos"], 0);
}

#[tokio::test]
async fn directory_trash_requires_exact_confirmation_and_protects_root() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    state
        .jobs
        .add_folder("photos", state.jobs.root().to_str().unwrap())
        .unwrap();
    let source = state.jobs.root().join("folder");
    std::fs::create_dir(&source).unwrap();
    std::fs::write(source.join("photo.raw"), b"unchanged").unwrap();
    let app = router(state.clone());
    for body in [
        json!({"path":source, "confirmationName":"folder ","requestID":uuid::Uuid::new_v4()}),
        json!({"path":state.jobs.root(), "confirmationName":"originals","requestID":uuid::Uuid::new_v4()}),
    ] {
        let (status, _) = call(
            app.clone(),
            "POST",
            "/libraries/photos/directories/trash",
            body,
        )
        .await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    }
    assert_eq!(
        std::fs::read(source.join("photo.raw")).unwrap(),
        b"unchanged"
    );
}

#[tokio::test]
async fn directory_trash_returns_durable_task_and_status_without_running_native_program() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    state
        .jobs
        .add_folder("photos", state.jobs.root().to_str().unwrap())
        .unwrap();
    let source = state.jobs.root().join("folder");
    std::fs::create_dir(&source).unwrap();
    let app = router(state);
    let id = uuid::Uuid::new_v4().to_string();
    let route = "/libraries/photos/directories/trash";
    let body = json!({"path":source,"confirmationName":"folder","requestID":id});
    let (status, task) = call(app.clone(), "POST", route, body.clone()).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(task["status"], "pending");
    assert_eq!(task["phase"], "waiting");
    let (status, duplicate) = call(app.clone(), "POST", route, body).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(duplicate, task);
    let (status, read) = call(app.clone(), "GET", &format!("{route}/{id}"), json!(null)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(read, task);
    let (status, _) = call(
        app.clone(),
        "POST",
        route,
        json!({"path":source,"confirmationName":"folder"}),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let (status, _) = call(
        app.clone(),
        "POST",
        route,
        json!({"path":source,"confirmationName":"folder","requestID":uuid::Uuid::new_v4()}),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (status, _) = call(
        app,
        "GET",
        &format!("{route}/{}", uuid::Uuid::new_v4()),
        json!(null),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(source.exists());
}

#[tokio::test]
async fn directory_rename_accepts_name_and_rejects_reused_request_for_another_name() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    state
        .jobs
        .add_folder("photos", state.jobs.root().to_str().unwrap())
        .unwrap();
    let source = state.jobs.root().join("old");
    std::fs::create_dir(&source).unwrap();
    std::fs::write(source.join("photo.raw"), b"original").unwrap();
    let app = router(state.clone());
    let id = uuid::Uuid::new_v4().to_string();
    let body = json!({"path":source,"parentPath":state.jobs.root(),"name":"new","requestID":id});
    let (status, task) = call(
        app.clone(),
        "POST",
        "/libraries/photos/directories/move-tasks",
        body.clone(),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(
        task["destination"],
        state.jobs.root().join("new").to_str().unwrap()
    );
    let mut different = body.clone();
    different["name"] = json!("different");
    assert_eq!(
        call(
            app.clone(),
            "POST",
            "/libraries/photos/directories/move-tasks",
            different
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let (status, moved) = call(
        app.clone(),
        "POST",
        "/libraries/photos/directories/move",
        body.clone(),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(moved["path"], task["destination"]);
    assert_eq!(
        call(app, "POST", "/libraries/photos/directories/move", body).await,
        (StatusCode::OK, moved)
    );
    assert_eq!(
        std::fs::read(state.jobs.root().join("new/photo.raw")).unwrap(),
        b"original"
    );
    assert!(!source.exists());
}

#[tokio::test]
async fn directory_move_tasks_return_durable_progress_and_keep_sync_endpoint() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    state
        .jobs
        .add_folder("photos", state.jobs.root().to_str().unwrap())
        .unwrap();
    let source = state.jobs.root().join("queued");
    let parent = state.jobs.root().join("target");
    std::fs::create_dir(&source).unwrap();
    std::fs::create_dir(&parent).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let app = router(state.clone());
    let body = json!({"path":source,"parentPath":parent,"requestID":id});
    let (status, task) = call(
        app.clone(),
        "POST",
        "/libraries/photos/directories/move-tasks",
        body.clone(),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(task["status"], "pending");
    assert_eq!(task["phase"], "waiting");
    assert_eq!(task["destination"], parent.join("queued").to_str().unwrap());
    assert!(source.exists());
    assert_eq!(
        call(
            app.clone(),
            "GET",
            &format!("/libraries/photos/directories/move-tasks/{id}"),
            Value::Null
        )
        .await,
        (StatusCode::OK, task.clone())
    );
    assert_eq!(
        call(
            app.clone(),
            "POST",
            "/libraries/photos/directories/move-tasks",
            body
        )
        .await,
        (StatusCode::ACCEPTED, task)
    );
    let sync = state.jobs.root().join("legacy");
    std::fs::create_dir(&sync).unwrap();
    let (status, result) = call(
        app,
        "POST",
        "/libraries/photos/directories/move",
        json!({"path":sync,"parentPath":parent,"requestID":uuid::Uuid::new_v4().to_string()}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(result["previousPath"], sync.to_str().unwrap());
    assert_eq!(result["path"], parent.join("legacy").to_str().unwrap());
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let worker = std::thread::spawn({
        let jobs = state.jobs.clone();
        let store = state.store.clone();
        let stop = stop.clone();
        move || keeps_server::directory_move::run(jobs, store, stop)
    });
    let app = router(state);
    let mut completed = false;
    for _ in 0..100 {
        let (status, task) = call(
            app.clone(),
            "GET",
            &format!("/libraries/photos/directories/move-tasks/{id}"),
            Value::Null,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        if task["status"] == "completed" {
            completed = true;
            break;
        }
        if task["status"] == "failed" {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    worker.join().unwrap().unwrap();
    assert!(
        completed,
        "background worker must finish without another submission"
    );
    assert!(parent.join("queued").exists());
    assert!(!source.exists());
}

#[tokio::test]
async fn browse_thumbnail_signed_download_and_stale_source_exclusion() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let id = seed(&state, dir.path(), "browse.jpg");
    state.store.reconcile_cache().unwrap();
    let generated = dir.path().join("browse.heic");
    let bytes = b"browse-object-transport-fixture";
    std::fs::write(&generated, bytes).unwrap();
    let object = state
        .previews
        .put_generated_role("photos", &id, "browse-hash", &generated, "browse")
        .unwrap();
    let source = dir.path().join("originals/browse.jpg");
    let standard = json!({"path":source,"width":4000,"height":3000,"version":"browse.jpg","sizeBytes":14,"mtimeNs":keeps_server::cache_pipeline::file_mtime(&source).unwrap()});
    let db = rusqlite::Connection::open(dir.path().join("keeps/db/control_plane.sqlite")).unwrap();
    let thumb = json!({"objectRef":object,"width":512,"height":384,"version":"preview-v1"});
    let version = format!("{}:browse-hash", keeps_server::browse_cache::SPEC);
    let browse = json!({"objectRef":object,"width":64,"height":48,"version":version,"spec":keeps_server::browse_cache::SPEC,"sourceThumbnailVersion":"preview-v1"});
    db.execute(
        "UPDATE media_cache SET status='ready',thumbnail=?,standard=?,browse_thumbnail=?",
        rusqlite::params![thumb.to_string(), standard.to_string(), browse.to_string()],
    )
    .unwrap();
    let app = router(state);
    let asset_path = format!("/libraries/photos/assets/{id}");
    let metadata_path = format!("/derivatives/{id}?role=browse&libraryID=photos");
    let unauthenticated = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(&metadata_path)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(unauthenticated.status(), StatusCode::UNAUTHORIZED);
    let (status, asset) = call(app.clone(), "GET", &asset_path, Value::Null).await;
    assert_eq!(status, StatusCode::OK, "{asset}");
    assert_eq!(asset["browseThumbnail"]["width"], 64);
    assert_eq!(asset["browseThumbnail"]["version"], version);
    let (status, metadata) = call(app.clone(), "GET", &metadata_path, Value::Null).await;
    assert_eq!(status, StatusCode::OK, "{metadata}");
    for key in ["width", "height", "version"] {
        assert_eq!(metadata[key], asset["browseThumbnail"][key]);
    }
    let url = url::Url::parse(metadata["downloadURL"].as_str().unwrap()).unwrap();
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(url.path())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.headers()["content-type"],
        "application/octet-stream"
    );
    assert_eq!(
        response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .as_ref(),
        bytes
    );
    assert_ne!(
        call(
            app.clone(),
            "GET",
            &format!("{}tampered", url.path()),
            Value::Null
        )
        .await
        .0,
        StatusCode::OK
    );
    db.execute(
        "UPDATE media_cache SET thumbnail=json_set(thumbnail,'$.version','preview-v2')",
        [],
    )
    .unwrap();
    assert_eq!(
        call(app.clone(), "GET", &metadata_path, Value::Null)
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    assert!(
        call(app.clone(), "GET", &asset_path, Value::Null).await.1["browseThumbnail"].is_null()
    );
    db.execute(
        "UPDATE media_cache SET thumbnail=json_set(thumbnail,'$.version','preview-v1')",
        [],
    )
    .unwrap();
    db.execute(
        "UPDATE catalog_defaults SET content_hash='changed-original'",
        [],
    )
    .unwrap();
    db.execute(
        "UPDATE catalog_assets SET content_hash='changed-original'",
        [],
    )
    .unwrap();
    assert_eq!(
        call(app.clone(), "GET", &metadata_path, Value::Null)
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    assert!(call(app, "GET", &asset_path, Value::Null).await.1["browseThumbnail"].is_null());
}

#[tokio::test]
async fn photo_move_tasks_are_durable_scoped_and_idempotent() {
    let tmp = tempfile::tempdir().unwrap();
    let state = state(tmp.path());
    let app = router(state.clone());
    let root = state.jobs.root().to_str().unwrap();
    let request_id = uuid::Uuid::new_v4().to_string();
    let body = json!({"requestID":request_id,"assetIDs":[uuid::Uuid::new_v4().to_string()],"sourcePath":format!("{root}/source"),"parentPath":format!("{root}/target")});
    let path = "/libraries/photos/assets/move-tasks";
    let denied = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(path)
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::UNAUTHORIZED);

    let (status, task) = call(app.clone(), "POST", path, body.clone()).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(task["id"], request_id);
    assert_eq!(task["status"], "pending");
    assert_eq!(task["assetIDs"], body["assetIDs"]);
    let (status, repeated) = call(app.clone(), "POST", path, body.clone()).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(repeated, task);
    let (status, read) = call(
        app.clone(),
        "GET",
        &format!("{path}/{request_id}"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(read, task);
    let mut conflict = body;
    conflict["parentPath"] = json!(format!("{root}/different"));
    assert_eq!(
        call(app.clone(), "POST", path, conflict).await.0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        call(
            app,
            "GET",
            &format!("/libraries/other/assets/move-tasks/{request_id}"),
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn rejected_trash_requires_auth_frozen_inventory_and_matching_count() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    state
        .jobs
        .add_folder("photos", state.jobs.root().to_str().unwrap())
        .unwrap();
    let id = seed(&state, &dir.path().canonicalize().unwrap(), "rejected.jpg");
    state
        .store
        .patch_asset("photos", &id, &json!({"flagState":"rejected"}))
        .unwrap();
    let app = router(state.clone());
    let preview_path = "/libraries/photos/rejected-trash/preview";
    let unauthenticated = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(preview_path)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(unauthenticated.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        call(
            app.clone(),
            "POST",
            "/libraries/other/rejected-trash/preview",
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let (status, preview) = call(app.clone(), "POST", preview_path, Value::Null).await;
    assert_eq!(status, StatusCode::OK, "{preview}");
    assert_eq!(preview["count"], 1);
    assert_eq!(preview["status"], "draft");
    assert_eq!(preview["completedFiles"], 0);
    let task_path = format!(
        "/libraries/photos/rejected-trash/{}",
        preview["id"].as_str().unwrap()
    );
    assert_eq!(
        call(
            app.clone(),
            "POST",
            &task_path,
            json!({"confirmationCount":2})
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        call(app.clone(), "GET", &task_path, Value::Null).await.1["status"],
        "draft"
    );
    let (status, submitted) = call(
        app.clone(),
        "POST",
        &task_path,
        json!({"confirmationCount":1}),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED, "{submitted}");
    assert_eq!(submitted["status"], "pending");
    assert_eq!(
        call(
            app.clone(),
            "POST",
            &task_path,
            json!({"confirmationCount":1})
        )
        .await
        .1["id"],
        preview["id"]
    );
    let (_, second) = call(app.clone(), "POST", preview_path, Value::Null).await;
    let second_path = format!(
        "/libraries/photos/rejected-trash/{}",
        second["id"].as_str().unwrap()
    );
    assert_eq!(
        call(
            app.clone(),
            "POST",
            &second_path,
            json!({"confirmationCount":1})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    state
        .store
        .patch_asset("photos", &id, &json!({"flagState":"picked"}))
        .unwrap();
    assert_eq!(
        call(
            app.clone(),
            "POST",
            &second_path,
            json!({"confirmationCount":1})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert!(dir.path().join("originals/rejected.jpg").exists());
}

#[tokio::test]
async fn directory_metadata_refresh_is_recursive_manual_durable_and_scoped() {
    let dir = tempfile::tempdir().unwrap();
    let state = state(dir.path());
    let root = state.jobs.root().to_path_buf();
    std::fs::create_dir_all(root.join("tracked/sub/nested")).unwrap();
    std::fs::create_dir(root.join("untracked")).unwrap();
    let folder = state.jobs.add_folder("photos", "tracked").unwrap();
    let app = router(state.clone());
    let endpoint = "/libraries/photos/directories/refresh";
    let path = root.join("tracked/sub");
    let (status, job) = call(app.clone(), "POST", endpoint, json!({"path":path})).await;
    assert_eq!(status, StatusCode::ACCEPTED, "{job}");
    assert_eq!(job["folderID"], folder.id);
    assert_eq!(job["path"], path.to_str().unwrap());
    assert_eq!(job["scopeKind"], "recursive");
    assert_eq!(job["workClass"], "manual");
    assert_eq!(job["refreshMetadata"], true);
    assert_eq!(job["pathSync"], false);
    assert_eq!(job["waitForQuiet"], false);
    assert_eq!(job["status"], "pending");
    let (_, repeated) = call(app.clone(), "POST", endpoint, json!({"path":path})).await;
    assert_eq!(repeated["id"], job["id"]);
    let (_, summary) = call(
        app.clone(),
        "GET",
        "/libraries/photos/task-status",
        Value::Null,
    )
    .await;
    assert_eq!(summary["longTask"]["kind"], "manual");
    assert_eq!(summary["longTask"]["path"], path.to_str().unwrap());
    assert_eq!(summary["longTask"]["processed"], 0);
    assert_eq!(summary["longTask"]["failed"], 0);
    assert_eq!(
        call(
            app.clone(),
            "POST",
            endpoint,
            json!({"path":root.join("untracked")})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    for rejected in [
        root.join("tracked/missing"),
        root.join("tracked/../untracked"),
        dir.path().to_path_buf(),
    ] {
        assert_eq!(
            call(app.clone(), "POST", endpoint, json!({"path":rejected}))
                .await
                .0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
    }
    let claimed = state.jobs.claim_class("manual").unwrap().unwrap();
    let current = path.join("nested/photo.jpg");
    state
        .jobs
        .update_progress(&claimed.id, 7, 0, 2, current.to_str())
        .unwrap();
    keeps_server::tasks::begin(&state.jobs, "photos", "manual", current.to_str()).unwrap();
    let (_, running) = call(
        app.clone(),
        "GET",
        "/libraries/photos/task-status",
        Value::Null,
    )
    .await;
    assert_eq!(running["longTask"]["status"], "running");
    assert_eq!(running["longTask"]["path"], path.to_str().unwrap());
    assert_eq!(
        running["longTask"]["currentPhoto"],
        current.to_str().unwrap()
    );
    assert_eq!(running["longTask"]["processed"], 7);
    assert_eq!(running["longTask"]["failed"], 2);
    state.jobs.remove_folder(&folder.id).unwrap();
    assert_eq!(
        call(app, "POST", endpoint, json!({"path":path})).await.0,
        StatusCode::NOT_FOUND
    );
    let reopened = Jobs::open(&dir.path().join("keeps/db/jobs.sqlite"), &root).unwrap();
    let saved = reopened.job(job["id"].as_str().unwrap()).unwrap().unwrap();
    assert!(saved.refresh_metadata);
    assert_eq!(saved.path, path.to_str().unwrap());
}
