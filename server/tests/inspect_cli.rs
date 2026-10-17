use serde_json::{Value, json};
use std::{
    io::Write,
    process::{Command, Stdio},
};

#[test]
fn inspection_is_streaming_read_only_and_independent_of_catalog() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let photo = root.join("sample.png");
    let bytes: &[u8] = &[
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 3, 8, 2,
        0, 0, 0, 54, 136, 73, 214, 0, 0, 0, 11, 73, 68, 65, 84, 120, 156, 99, 96, 192, 2, 0, 0, 21,
        0, 1, 170, 101, 151, 196, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    ];
    std::fs::write(&photo, bytes).unwrap();
    let link = root.join("link.png");
    std::os::unix::fs::symlink(&photo, &link).unwrap();
    let directory_link = root.join("linked-directory");
    std::os::unix::fs::symlink(&root, &directory_link).unwrap();
    let missing = root.join("missing.jpg");
    let mut child = Command::new(env!("CARGO_BIN_EXE_keeps-inspect"))
        .env_remove("KEEPS_ROOT")
        .env("PATH", &root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    writeln!(input, "invalid JSON").unwrap();
    for path in [&missing, &link, &directory_link.join("sample.png"), &photo] {
        writeln!(input, "{}", json!({"path":path})).unwrap();
    }
    drop(input);
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let responses: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(responses.len(), 5);
    assert!(
        responses[0]["error"]
            .as_str()
            .unwrap()
            .contains("parsing inspection request:")
    );
    let missing_error = responses[1]["error"].as_str().unwrap();
    assert!(missing_error.contains("stat ") && missing_error.contains("os error"));
    for response in &responses[2..4] {
        assert!(
            response["error"]
                .as_str()
                .unwrap()
                .contains("symlink is not supported")
        );
    }
    let result = &responses[4];
    assert!(result.get("error").is_none(), "{result}");
    assert_eq!(result["path"], photo.to_str().unwrap());
    assert_eq!(
        result["sha256"],
        keeps_server::media::sha256_file(&photo).unwrap()
    );
    assert!(result["capture"]["captureTime"].is_null());
    assert_eq!(result["width"], 2);
    assert_eq!(result["height"], 3);
    assert_eq!(result["priority"], 2);
    assert!(result["visual_hash"].is_null());
    assert_eq!(result["stamp"]["size"], bytes.len());
    assert_eq!(std::fs::read(&photo).unwrap(), bytes);
    assert!(!root.join("catalog.sqlite").exists());
}
