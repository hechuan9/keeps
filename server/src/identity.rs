use anyhow::{Context, Result, ensure};
use std::{
    io::Write,
    path::{Path, PathBuf},
    process::Command,
    str::FromStr,
};
use uuid::Uuid;
use xmp_toolkit::{XmpMeta, XmpValue};

const IDENTIFIER_PREFIX: &str = "https://keeps.photos/photo/";
const XMP: &str = "http://ns.adobe.com/xap/1.0/";
const MM: &str = "http://ns.adobe.com/xap/1.0/mm/";
const KEEPS_NAMESPACE: &str = "https://keeps.photos/ns/1.0/";

#[derive(Debug)]
pub struct IdentityWrite {
    pub id: String,
    pub changed: bool,
    pub path: PathBuf,
}

pub fn normalize(value: &str) -> Option<String> {
    let value = value.trim();
    let value = ["urn:uuid:", "xmp.did:", "uuid:"]
        .into_iter()
        .find_map(|prefix| {
            value
                .get(..prefix.len())
                .filter(|head| head.eq_ignore_ascii_case(prefix))
                .map(|_| &value[prefix.len()..])
        })
        .unwrap_or(value);
    Uuid::parse_str(value)
        .ok()
        .filter(|id| !id.is_nil())
        .map(|id| id.to_string())
}

fn run(command: &mut Command) -> Result<Vec<u8>> {
    crate::media::run(command)
}

#[cfg(test)]
pub(crate) fn exiftool() -> Result<Command> {
    use std::sync::OnceLock;
    static CONFIG: OnceLock<tempfile::NamedTempFile> = OnceLock::new();
    if CONFIG.get().is_none() {
        use std::io::Write;
        let mut config = tempfile::NamedTempFile::new()?;
        config.write_all(br#"%Image::ExifTool::UserDefined = (
 'Image::ExifTool::XMP::Main' => { keeps => { SubDirectory => { TagTable => 'Image::ExifTool::UserDefined::keeps' } } },
);
%Image::ExifTool::UserDefined::keeps = (
 GROUPS => { 0 => 'XMP', 1 => 'XMP-keeps', 2 => 'Image' },
 NAMESPACE => { keeps => 'https://keeps.photos/ns/1.0/' },
 WRITABLE => 'string', PhotoID => {},
);
1;
"#)?;
        let _ = CONFIG.set(config);
    }
    let mut command = Command::new("exiftool");
    command.arg("-config").arg(CONFIG.get().unwrap().path());
    Ok(command)
}

pub fn identifier_photo_id(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(value) => {
            value.strip_prefix(IDENTIFIER_PREFIX).and_then(normalize)
        }
        serde_json::Value::Array(values) => values.iter().find_map(identifier_photo_id),
        _ => None,
    }
}

fn embedded(path: &Path) -> Result<Option<String>> {
    crate::native_metadata::embedded_photo_id(path)
}

pub fn sidecar_path(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(".xmp");
    PathBuf::from(name)
}

pub fn read_photo_id(path: &Path) -> Result<Option<String>> {
    if let Some(id) = sidecar_photo_id(path)? {
        return Ok(Some(id));
    }
    if let Some(id) = embedded(path)? {
        return Ok(Some(id));
    }
    for sidecar in crate::media::sidecars(path)? {
        if sidecar != path
            && let Some(id) = embedded(&sidecar)?
        {
            return Ok(Some(id));
        }
    }
    Ok(None)
}

pub fn read(path: &Path) -> Result<Option<String>> {
    let metadata = crate::media::MediaProcessor::new().extract(path)?;
    Ok(metadata
        .photo_id
        .or_else(|| metadata.original_document_id.as_deref().and_then(normalize)))
}

fn read_sidecar(path: &Path) -> Result<Option<XmpMeta>> {
    let info = match std::fs::symlink_metadata(path) {
        Ok(info) => info,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).with_context(|| format!("inspecting {}", path.display())),
    };
    ensure!(
        info.file_type().is_file(),
        "metadata target must be a regular file: {}",
        path.display()
    );
    let xml =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    Ok(Some(
        XmpMeta::from_str(&xml).with_context(|| format!("parsing {}", path.display()))?,
    ))
}

fn standard_meta_photo_id(meta: &XmpMeta) -> Option<String> {
    meta.property_array(XMP, "Identifier")
        .find_map(|value| {
            value
                .value
                .strip_prefix(IDENTIFIER_PREFIX)
                .and_then(normalize)
        })
        .or_else(|| {
            meta.property(XMP, "Identifier").and_then(|value| {
                value
                    .value
                    .strip_prefix(IDENTIFIER_PREFIX)
                    .and_then(normalize)
            })
        })
}

fn meta_photo_id(meta: &XmpMeta) -> Option<String> {
    standard_meta_photo_id(meta).or_else(|| {
        meta.property(KEEPS_NAMESPACE, "PhotoID")
            .and_then(|value| normalize(&value.value))
    })
}

pub fn standard_sidecar_photo_id(path: &Path) -> Result<Option<String>> {
    Ok(read_sidecar(&sidecar_path(path))?.and_then(|meta| standard_meta_photo_id(&meta)))
}

pub fn sidecar_photo_id(path: &Path) -> Result<Option<String>> {
    Ok(read_sidecar(&sidecar_path(path))?.and_then(|meta| meta_photo_id(&meta)))
}

fn update_meta(
    meta: &mut XmpMeta,
    id: &str,
    source: Option<&crate::media::Metadata>,
) -> Result<bool> {
    if meta
        .property_array(XMP, "Identifier")
        .any(|v| v.value == format!("{IDENTIFIER_PREFIX}{id}"))
    {
        return Ok(false);
    }
    // A photo identifier links versions; Adobe document identifiers keep their original scope.
    if let Some(source) = source {
        for (field, value) in [
            ("DocumentID", source.document_id.as_ref()),
            ("OriginalDocumentID", source.original_document_id.as_ref()),
            ("InstanceID", source.instance_id.as_ref()),
        ] {
            if meta.property(MM, field).is_none()
                && let Some(value) = value
            {
                meta.set_property(MM, field, &XmpValue::new(value.clone()))?;
            }
        }
        if meta.property(XMP, "Rating").is_none() {
            meta.set_property_i32(
                XMP,
                "Rating",
                &XmpValue::new(source.xmp_rating.unwrap_or(i32::try_from(source.rating)?)),
            )?;
        }
        if meta
            .property("http://ns.adobe.com/exif/1.0/", "DateTimeOriginal")
            .is_none()
            && let Some(date) = &source.capture_time
        {
            meta.set_property(
                "http://ns.adobe.com/exif/1.0/",
                "DateTimeOriginal",
                &XmpValue::new(date.clone()),
            )?;
        }
    }
    let old: Vec<_> = meta
        .property_array(XMP, "Identifier")
        .enumerate()
        .filter(|(_, value)| value.value.starts_with(IDENTIFIER_PREFIX))
        .map(|(index, _)| index + 1)
        .collect();
    for index in old.into_iter().rev() {
        meta.delete_array_item(XMP, "Identifier", index as i32)?;
    }
    meta.append_array_item(
        XMP,
        &XmpValue::new("Identifier".to_owned()).set_is_array(true),
        &XmpValue::new(format!("{IDENTIFIER_PREFIX}{id}")),
    )?;
    if meta.property(MM, "DocumentID").is_none() {
        meta.set_property(
            MM,
            "DocumentID",
            &XmpValue::new(format!("urn:uuid:{}", Uuid::new_v4())),
        )?;
    }
    meta.set_property(
        MM,
        "InstanceID",
        &XmpValue::new(format!("urn:uuid:{}", Uuid::new_v4())),
    )?;
    meta.set_property(
        XMP,
        "MetadataDate",
        &XmpValue::new(chrono::Utc::now().to_rfc3339()),
    )?;
    Ok(true)
}

fn write_sidecar_metadata(
    path: &Path,
    id: &str,
    source: Option<&crate::media::Metadata>,
) -> Result<bool> {
    let mut meta = read_sidecar(path)?.unwrap_or_default();
    if !update_meta(&mut meta, id, source)? {
        return Ok(false);
    }
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary.write_all(meta.to_string().as_bytes())?;
    temporary.as_file().sync_all()?;
    temporary
        .persist(path)
        .with_context(|| format!("saving {}", path.display()))?;
    std::fs::File::open(parent)?.sync_all()?;
    Ok(true)
}

#[cfg(test)]
fn write(path: &Path, id: &str) -> Result<()> {
    if let Ok(info) = std::fs::symlink_metadata(path) {
        ensure!(
            info.file_type().is_file(),
            "metadata target must be a regular file"
        );
    }
    run(exiftool()?
        .args(["-overwrite_original", "-P"])
        .arg(format!("-XMP-keeps:PhotoID={id}"))
        .arg("--")
        .arg(path))?;
    Ok(())
}

pub fn ensure(path: &Path, proposed_id: &str) -> Result<IdentityWrite> {
    let existing = read_photo_id(path)?;
    ensure_known(path, existing.as_deref().unwrap_or(proposed_id))
}

pub fn ensure_known(path: &Path, proposed_id: &str) -> Result<IdentityWrite> {
    let id = normalize(proposed_id).context("invalid proposed photo identity UUID")?;
    let destination = sidecar_path(path);
    let changed = write_sidecar_metadata(&destination, &id, None)?;
    Ok(IdentityWrite {
        id,
        changed,
        path: destination,
    })
}

pub fn ensure_metadata(
    path: &Path,
    proposed_id: &str,
    source: &crate::media::Metadata,
) -> Result<IdentityWrite> {
    let id = normalize(proposed_id).context("invalid proposed photo identity UUID")?;
    let destination = sidecar_path(path);
    let changed = write_sidecar_metadata(&destination, &id, Some(source))?;
    Ok(IdentityWrite {
        id,
        changed,
        path: destination,
    })
}

fn mark_generated(meta: &mut XmpMeta, id: &str) -> Result<()> {
    let source_document = meta.property(MM, "DocumentID");
    let source_instance = meta.property(MM, "InstanceID");
    update_meta(meta, id, None)?;
    if let Some(source) = source_document {
        if meta.property(MM, "OriginalDocumentID").is_none() {
            meta.set_property(MM, "OriginalDocumentID", &source)?;
        }
        meta.delete_property(MM, "DerivedFrom")?;
        let resource_ref = "http://ns.adobe.com/xap/1.0/sType/ResourceRef#";
        meta.set_struct_field(MM, "DerivedFrom", resource_ref, "documentID", &source)?;
        if let Some(source) = source_instance {
            meta.set_struct_field(MM, "DerivedFrom", resource_ref, "instanceID", &source)?;
        }
    }
    meta.set_property(
        MM,
        "DocumentID",
        &XmpValue::new(format!("urn:uuid:{}", Uuid::new_v4())),
    )?;
    meta.set_property(
        MM,
        "InstanceID",
        &XmpValue::new(format!("urn:uuid:{}", Uuid::new_v4())),
    )?;
    meta.set_property(
        XMP,
        "MetadataDate",
        &XmpValue::new(chrono::Utc::now().to_rfc3339()),
    )?;
    Ok(())
}

pub fn generated(path: &Path, root_id: &str) -> Result<()> {
    let id = normalize(root_id).context("invalid generated photo identity UUID")?;
    ensure!(
        std::fs::symlink_metadata(path)?.file_type().is_file(),
        "generated photo must be a regular file"
    );
    let packet = run(Command::new("exiftool")
        .args(["-b", "-XMP", "--"])
        .arg(path))?;
    let mut meta = if packet.is_empty() {
        XmpMeta::default()
    } else {
        XmpMeta::from_str(std::str::from_utf8(&packet)?)?
    };
    mark_generated(&mut meta, &id)?;
    let mut temporary = tempfile::NamedTempFile::new()?;
    temporary.write_all(meta.to_string().as_bytes())?;
    run(Command::new("exiftool")
        .args(["-overwrite_original", "-P"])
        .arg(format!("-XMP<={}", temporary.path().display()))
        .arg("--")
        .arg(path))?;
    Ok(())
}

#[cfg(test)]
fn write_sidecar(path: &Path, id: &str) -> Result<bool> {
    write_sidecar_metadata(path, id, None)
}

#[cfg(test)]
mod tests {
    #[test]
    fn scalar_standard_identifier_precedes_legacy_identity() -> anyhow::Result<()> {
        let meta: xmp_toolkit::XmpMeta = r#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:keeps="https://keeps.photos/ns/1.0/" xmp:Identifier="https://keeps.photos/photo/77777777-7777-4777-8777-777777777777" keeps:PhotoID="66666666-6666-4666-8666-666666666666"/></rdf:RDF></x:xmpmeta>"#.parse()?;
        assert_eq!(
            super::meta_photo_id(&meta).as_deref(),
            Some("77777777-7777-4777-8777-777777777777")
        );
        assert_eq!(
            super::standard_meta_photo_id(&meta),
            super::meta_photo_id(&meta)
        );
        Ok(())
    }

    use super::*;

    #[test]
    fn standard_identity_preserves_adobe_and_unrelated_identifiers() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let photo = dir.path().join("photo.3FR");
        let mut meta = XmpMeta::default();
        meta.append_array_item(
            XMP,
            &XmpValue::new("Identifier".into()).set_is_array(true),
            &XmpValue::new("third-party:123".into()),
        )?;
        meta.set_property(MM, "DocumentID", &XmpValue::new("adobe-document".into()))?;
        meta.set_property(
            MM,
            "OriginalDocumentID",
            &XmpValue::new("adobe-original".into()),
        )?;
        std::fs::write(sidecar_path(&photo), meta.to_string())?;
        let id = Uuid::new_v4().to_string();
        ensure_known(&photo, &id)?;
        let result = read_sidecar(&sidecar_path(&photo))?.unwrap();
        assert!(
            result
                .property_array(XMP, "Identifier")
                .any(|v| v.value == "third-party:123")
        );
        assert_eq!(
            result.property(MM, "DocumentID").unwrap().value,
            "adobe-document"
        );
        assert_eq!(
            result.property(MM, "OriginalDocumentID").unwrap().value,
            "adobe-original"
        );
        assert!(result.property(KEEPS_NAMESPACE, "PhotoID").is_none());
        assert_eq!(
            standard_sidecar_photo_id(&photo)?.as_deref(),
            Some(id.as_str())
        );
        let heif = dir.path().join("photo.HEIC");
        ensure_known(&heif, &id)?;
        let other = read_sidecar(&sidecar_path(&heif))?.unwrap();
        assert_eq!(meta_photo_id(&result), meta_photo_id(&other));
        assert_ne!(
            result.property(MM, "DocumentID"),
            other.property(MM, "DocumentID")
        );
        assert!(other.property(MM, "OriginalDocumentID").is_none());
        Ok(())
    }

    #[test]
    fn new_sidecar_inherits_embedded_document_rating_and_date() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let photo = dir.path().join("photo.ARW");
        let source = crate::media::Metadata {
            document_id: Some("source-document".into()),
            instance_id: Some("source-instance".into()),
            rating: 0,
            xmp_rating: Some(-1),
            original_document_id: Some("source-original".into()),
            capture_time: Some("2024-08-25T10:25:14-05:00".into()),
            ..Default::default()
        };
        ensure_metadata(&photo, &Uuid::new_v4().to_string(), &source)?;
        let meta = read_sidecar(&sidecar_path(&photo))?.unwrap();
        assert_eq!(
            meta.property(MM, "DocumentID").unwrap().value,
            "source-document"
        );
        assert_ne!(
            meta.property(MM, "InstanceID").unwrap().value,
            "source-instance"
        );
        assert_eq!(
            meta.property(MM, "OriginalDocumentID").unwrap().value,
            "source-original"
        );
        assert_eq!(meta.property(XMP, "Rating").unwrap().value, "-1");
        assert_eq!(
            meta.property("http://ns.adobe.com/exif/1.0/", "DateTimeOriginal")
                .unwrap()
                .value,
            source.capture_time.unwrap()
        );
        Ok(())
    }

    #[test]
    fn legacy_identity_remains_readable_and_standard_has_priority() -> Result<()> {
        XmpMeta::register_namespace(KEEPS_NAMESPACE, "keeps")?;
        let mut meta = XmpMeta::default();
        let legacy = Uuid::new_v4().to_string();
        let standard = Uuid::new_v4().to_string();
        meta.set_property(KEEPS_NAMESPACE, "PhotoID", &XmpValue::new(legacy.clone()))?;
        assert_eq!(meta_photo_id(&meta).as_deref(), Some(legacy.as_str()));
        update_meta(&mut meta, &standard, None)?;
        assert_eq!(meta_photo_id(&meta).as_deref(), Some(standard.as_str()));
        assert_eq!(
            identifier_photo_id(&serde_json::json!([
                "other",
                format!("{IDENTIFIER_PREFIX}{standard}")
            ])),
            Some(standard)
        );
        Ok(())
    }

    #[test]
    fn generated_document_has_new_ids_and_real_source_chain() -> Result<()> {
        let mut meta = XmpMeta::default();
        meta.set_property(MM, "DocumentID", &XmpValue::new("source-doc".into()))?;
        meta.set_property(MM, "InstanceID", &XmpValue::new("source-instance".into()))?;
        let id = Uuid::new_v4().to_string();
        mark_generated(&mut meta, &id)?;
        assert_eq!(meta_photo_id(&meta).as_deref(), Some(id.as_str()));
        assert_ne!(meta.property(MM, "DocumentID").unwrap().value, "source-doc");
        assert_ne!(
            meta.property(MM, "InstanceID").unwrap().value,
            "source-instance"
        );
        assert_eq!(
            meta.property(MM, "OriginalDocumentID").unwrap().value,
            "source-doc"
        );
        assert_eq!(
            meta.struct_field(
                MM,
                "DerivedFrom",
                "http://ns.adobe.com/xap/1.0/sType/ResourceRef#",
                "documentID"
            )
            .unwrap()
            .value,
            "source-doc"
        );
        Ok(())
    }

    #[test]
    fn sidecar_identity_is_atomic_idempotent_and_preserves_lightroom() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let photo = dir.path().join("photo.ARW");
        std::fs::write(&photo, b"untouched original")?;
        let destination = sidecar_path(&photo);
        let xml = r#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" xmp:Rating="4" crs:Exposure2012="+0.14"/></rdf:RDF></x:xmpmeta>"#;
        std::fs::write(&destination, xml)?;
        let id = Uuid::new_v4().to_string();
        assert!(ensure_known(&photo, &id)?.changed);
        let bytes = std::fs::read(&destination)?;
        let modified = std::fs::metadata(&destination)?.modified()?;
        assert!(!ensure_known(&photo, &id)?.changed);
        assert_eq!(std::fs::metadata(&destination)?.modified()?, modified);
        assert_eq!(std::fs::read(&destination)?, bytes);
        assert_eq!(std::fs::read(&photo)?, b"untouched original");
        assert_eq!(read_photo_id(&photo)?.as_deref(), Some(id.as_str()));
        let meta = read_sidecar(&destination)?.unwrap();
        assert_eq!(
            meta.property("http://ns.adobe.com/xap/1.0/", "Rating")
                .unwrap()
                .value,
            "4"
        );
        assert_eq!(
            meta.property(
                "http://ns.adobe.com/camera-raw-settings/1.0/",
                "Exposure2012"
            )
            .unwrap()
            .value,
            "+0.14"
        );
        Ok(())
    }

    #[test]
    fn existing_embedded_hint_still_creates_authoritative_sidecar() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let photo = dir.path().join("photo.HEIC");
        let id = Uuid::new_v4().to_string();
        assert_eq!(sidecar_photo_id(&photo)?, None);
        assert!(ensure_known(&photo, &id)?.changed);
        assert_eq!(read_photo_id(&photo)?.as_deref(), Some(id.as_str()));
        Ok(())
    }

    #[test]
    fn dedicated_sidecar_wins_over_other_identity_sources() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let photo = dir.path().join("photo.xmp");
        let legacy = Uuid::new_v4().to_string();
        let current = Uuid::new_v4().to_string();
        write_sidecar(&photo, &legacy)?;
        write_sidecar(&sidecar_path(&photo), &current)?;
        assert_eq!(read_photo_id(&photo)?.as_deref(), Some(current.as_str()));
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_sidecar() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let photo = dir.path().join("photo.ARW");
        let target = dir.path().join("target.xmp");
        std::fs::write(&target, b"unchanged")?;
        std::os::unix::fs::symlink(&target, sidecar_path(&photo))?;
        assert!(ensure_known(&photo, &Uuid::new_v4().to_string()).is_err());
        assert!(sidecar_photo_id(&photo).is_err());
        assert_eq!(std::fs::read(&target)?, b"unchanged");
        Ok(())
    }

    #[test]
    fn normalizes_standard_uuid_forms() {
        let id = "c0421f3c-1637-467a-94b7-77be3450f4aa";
        for value in [
            id.to_owned(),
            format!("xmp.did:{id}"),
            format!("uuid:{id}"),
            format!("urn:uuid:{id}"),
            format!(" XMP.DID:{} ", id.to_uppercase()),
        ] {
            assert_eq!(normalize(&value).as_deref(), Some(id));
        }
        assert_eq!(normalize("not-a-uuid"), None);
        assert_eq!(normalize("00000000-0000-0000-0000-000000000000"), None);
    }

    #[test]
    fn sidecars_preserve_source_extension() {
        assert_eq!(
            sidecar_path(Path::new("/photos/one.3FR")),
            Path::new("/photos/one.3FR.xmp")
        );
        assert_ne!(
            sidecar_path(Path::new("one.3FR")),
            sidecar_path(Path::new("one.jpg"))
        );
    }

    #[test]
    #[ignore = "requires ExifTool"]
    fn dedicated_photo_id_preserves_external_identity_and_reads_sidecar() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let photo = directory.path().join("photo.xmp");
        let sidecar = sidecar_path(&photo);
        let legacy = "12121212-1212-4212-8212-121212121212";
        run(Command::new("exiftool")
            .arg(format!("-OriginalDocumentID=xmp.did:{legacy}"))
            .arg("-ImageUniqueID=0123456789abcdef0123456789abcdef")
            .arg(&photo))?;
        assert_eq!(read(&photo)?.as_deref(), Some(legacy));
        assert_eq!(read_photo_id(&photo)?, None);
        let id = Uuid::new_v4().to_string();
        write(&sidecar, &id)?;
        let metadata = crate::media::MediaProcessor::new().extract(&photo)?;
        assert_eq!(metadata.photo_id.as_deref(), Some(id.as_str()));
        assert_eq!(
            metadata.original_document_id.as_deref(),
            Some(format!("xmp.did:{legacy}").as_str())
        );
        assert_eq!(
            metadata.camera_image_id.as_deref(),
            Some("0123456789abcdef0123456789abcdef")
        );
        assert_eq!(metadata.capture_time, None);
        assert_eq!(read(&photo)?.as_deref(), Some(id.as_str()));
        let result = ensure_known(&photo, &id)?;
        assert!(result.changed);
        assert!(!ensure_known(&photo, &id)?.changed);
        write(&photo, &Uuid::new_v4().to_string())?;
        assert_eq!(
            crate::media::MediaProcessor::new()
                .extract(&photo)?
                .photo_id,
            Some(id)
        );
        assert_eq!(
            crate::media::MediaProcessor::new()
                .extract(&photo)?
                .original_document_id,
            metadata.original_document_id
        );
        Ok(())
    }

    #[test]
    #[ignore = "requires ExifTool and KEEPS_IDENTITY_SAMPLE_DIR"]
    fn real_generated_heif_uses_standard_identity_and_preserves_pixels() -> Result<()> {
        let source = PathBuf::from(std::env::var("KEEPS_IDENTITY_SAMPLE_DIR")?);
        let temporary = tempfile::tempdir()?;
        let path = temporary.path().join("generated.HEIC");
        std::fs::copy(source.join("B0014811.HEIC"), &path)?;
        let digest = |path: &Path| {
            run(Command::new("exiftool")
                .args(["-s3", "-ImageDataHash"])
                .arg(path))
        };
        let before = digest(&path)?;
        let packet = run(Command::new("exiftool").args(["-b", "-XMP"]).arg(&path))?;
        let old = XmpMeta::from_str(std::str::from_utf8(&packet)?)?;
        let id = Uuid::new_v4().to_string();
        generated(&path, &id)?;
        assert_eq!(embedded(&path)?.as_deref(), Some(id.as_str()));
        assert_eq!(digest(&path)?, before);
        assert!(!sidecar_path(&path).exists());
        let packet = run(Command::new("exiftool").args(["-b", "-XMP"]).arg(&path))?;
        let new = XmpMeta::from_str(std::str::from_utf8(&packet)?)?;
        assert!(new.property(KEEPS_NAMESPACE, "PhotoID").is_none());
        assert_ne!(
            old.property(MM, "DocumentID"),
            new.property(MM, "DocumentID")
        );
        if old.property(MM, "OriginalDocumentID").is_some() {
            assert_eq!(
                old.property(MM, "OriginalDocumentID"),
                new.property(MM, "OriginalDocumentID")
            );
        }
        Ok(())
    }

    #[test]
    #[ignore = "requires ExifTool and KEEPS_IDENTITY_SAMPLE_DIR containing B0014811 RAW/HEIC"]
    fn real_raw_heif_share_camera_identity_and_preserve_image_data() -> Result<()> {
        let source = PathBuf::from(std::env::var("KEEPS_IDENTITY_SAMPLE_DIR")?);
        let temporary = tempfile::tempdir()?;
        let processor = crate::media::MediaProcessor::new();
        let id = Uuid::new_v4().to_string();
        let mut camera_ids = Vec::new();
        for extension in ["3FR", "HEIC"] {
            let name = format!("B0014811.{extension}");
            let path = temporary.path().join(&name);
            std::fs::copy(source.join(name), &path)?;
            let before = processor.extract(&path)?;
            camera_ids.push(
                before
                    .camera_image_id
                    .clone()
                    .context("sample has no camera ID")?,
            );
            let image_hash = |path: &Path| -> Result<Vec<u8>> {
                let hash = run(Command::new("exiftool")
                    .args(["-s3", "-ImageDataHash"])
                    .arg(path))?;
                ensure!(!hash.is_empty(), "ExifTool image data digest missing");
                Ok(hash)
            };
            let image_before = image_hash(&path)?;
            let original_hash = crate::media::sha256_file(&path)?;
            let written = ensure_known(&path, &id)?;
            assert!(written.changed);
            let after = processor.extract(&path)?;
            assert_eq!(after.photo_id.as_deref(), Some(id.as_str()));
            assert_eq!(after.camera_image_id, before.camera_image_id);
            assert_eq!(after.original_document_id, before.original_document_id);
            assert_eq!(image_hash(&path)?, image_before);
            assert_eq!(crate::media::sha256_file(&path)?, original_hash);
            assert_eq!(written.path, sidecar_path(&path));
        }
        assert_eq!(camera_ids[0], camera_ids[1]);
        Ok(())
    }

    #[test]
    #[ignore = "requires ExifTool and ImageMagick"]
    fn metadata_roundtrip_preserves_identity_and_other_tags() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let photo = directory.path().join("photo.jpg");
        run(Command::new("convert")
            .args(["-size", "20x20", "xc:red"])
            .arg(&photo))?;
        run(Command::new("exiftool")
            .args(["-overwrite_original", "-Rating=4"])
            .arg(&photo))?;
        let original_pixels = run(Command::new("convert").arg(&photo).arg("rgb:-"))?;
        let id = Uuid::new_v4().to_string();
        assert!(ensure(&photo, &id)?.changed);
        let second = ensure(&photo, &Uuid::new_v4().to_string())?;
        assert!(!second.changed);
        assert_eq!(second.id, id);
        assert_eq!(read(&photo)?.as_deref(), Some(id.as_str()));
        assert_eq!(
            original_pixels,
            run(Command::new("convert").arg(&photo).arg("rgb:-"))?
        );
        assert_eq!(
            run(Command::new("exiftool")
                .args(["-s3", "-Rating"])
                .arg(&photo))?,
            b"4\n"
        );
        let sidecar = sidecar_path(Path::new("photo.3FR"));
        let sidecar = directory.path().join(sidecar);
        write(&sidecar, &id)?;
        assert_eq!(embedded(&sidecar)?.as_deref(), Some(id.as_str()));
        Ok(())
    }
}
