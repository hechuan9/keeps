use std::{path::Path, process::Command};

use anyhow::{Context, Result, ensure};
use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{Map, Value, json};
use xmp_toolkit::{OpenFileOptions, XmpFile};

pub(crate) fn read_tags(path: &Path) -> Result<Value> {
    ensure!(
        crate::media::is_video(path),
        "unsupported video metadata format: {}",
        path.display()
    );
    let output = crate::media::run(
        Command::new("ffprobe")
            .args([
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_streams",
                "-show_format",
                "-of",
                "json",
            ])
            .arg(path),
    )
    .with_context(|| format!("probing video metadata {}", path.display()))?;
    let probe: Value = serde_json::from_slice(&output).context("parsing ffprobe video metadata")?;
    let mut tags = probe_tags(&probe)?;
    let extension = path
        .extension()
        .and_then(|v| v.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if ["mov", "mp4", "m4v"].contains(&extension.as_str()) {
        let mut file = XmpFile::new()?;
        file.open_file(path, OpenFileOptions::default().for_read().only_xmp())
            .with_context(|| format!("opening Adobe video metadata {}", path.display()))?;
        if let Some(meta) = file.xmp() {
            crate::native_metadata::merge_xmp(&mut tags, &meta);
        }
    }
    Ok(Value::Object(tags))
}

fn probe_tags(probe: &Value) -> Result<Map<String, Value>> {
    let stream = probe["streams"]
        .as_array()
        .and_then(|streams| streams.first())
        .context("file contains no video stream")?;
    let mut tags = Map::new();
    for (field, key) in [
        ("width", "QuickTime:ImageWidth"),
        ("height", "QuickTime:ImageHeight"),
    ] {
        let size = stream[field]
            .as_u64()
            .filter(|v| *v > 0)
            .context("video dimensions unavailable")?;
        tags.insert(key.into(), json!(size));
    }
    let value = |key: &str| {
        probe["format"]["tags"][key]
            .as_str()
            .or_else(|| stream["tags"][key].as_str())
            .filter(|s| !s.is_empty())
    };
    if let Some(time) = value("creation_time") {
        let time = DateTime::parse_from_rfc3339(time).context("invalid ffprobe creation_time")?;
        tags.insert(
            "QuickTime:CreateDate".into(),
            json!(
                time.with_timezone(&Utc)
                    .to_rfc3339_opts(SecondsFormat::AutoSi, true)
            ),
        );
    }
    for (source, target) in [
        ("com.apple.quicktime.make", "EXIF:Make"),
        ("com.apple.quicktime.model", "EXIF:Model"),
    ] {
        if let Some(value) = value(source) {
            tags.insert(target.into(), json!(value));
        }
    }
    Ok(tags)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_utc_and_leaves_absent_date_unknown() -> Result<()> {
        let input = json!({"streams":[{"width":64,"height":48}], "format":{"tags":{"creation_time":"2024-09-19T10:00:00+02:00", "com.apple.quicktime.model":"iPhone"}}});
        let tags = probe_tags(&input)?;
        assert_eq!(tags["QuickTime:CreateDate"], "2024-09-19T08:00:00Z");
        assert_eq!(tags["EXIF:Model"], "iPhone");
        assert!(
            !probe_tags(&json!({"streams":[{"width":64,"height":48}]}))?
                .contains_key("QuickTime:CreateDate")
        );
        assert!(probe_tags(&json!({"streams":[]})).is_err());
        Ok(())
    }

    // The production command runner uses Linux prlimit.
    #[cfg(target_os = "linux")]
    #[test]
    fn generated_mp4_and_mkv_read_without_exiftool() -> Result<()> {
        let dir = tempfile::tempdir()?;
        for extension in ["mp4", "mkv"] {
            let path = dir.path().join(format!("sample.{extension}"));
            crate::media::run(
                Command::new("ffmpeg")
                    .args([
                        "-v",
                        "error",
                        "-f",
                        "lavfi",
                        "-i",
                        "color=size=64x48:rate=1",
                        "-frames:v",
                        "1",
                        "-c:v",
                        "mpeg4",
                        "-metadata",
                        "creation_time=2024-09-19T08:00:00Z",
                    ])
                    .arg(&path),
            )?;
            let tags = read_tags(&path)?;
            assert_eq!(tags["QuickTime:ImageWidth"], 64);
            assert_eq!(tags["QuickTime:ImageHeight"], 48);
            assert_eq!(tags["QuickTime:CreateDate"], "2024-09-19T08:00:00Z");
        }
        let invalid = dir.path().join("invalid.mp4");
        std::fs::write(&invalid, b"truncated video")?;
        assert!(read_tags(&invalid).is_err());
        assert!(read_tags(&dir.path().join("unsupported.webm")).is_err());
        Ok(())
    }
}
