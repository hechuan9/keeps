use anyhow::{Context, Result, bail, ensure};
use exif::{Field, In, Tag};
use serde_json::{Map, Value, json};
use std::{
    fs::{self, File},
    io::{BufReader, Read, Seek, SeekFrom},
    path::Path,
    str::FromStr,
};
use xmp_toolkit::{OpenFileOptions, XmpFile, XmpMeta};

const XMP: &str = "http://ns.adobe.com/xap/1.0/";
const EXIF: &str = "http://ns.adobe.com/exif/1.0/";
const MM: &str = "http://ns.adobe.com/xap/1.0/mm/";
const SUPPORTED: &[&str] = &[
    "3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq", "kdc", "mef", "mos",
    "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "jpg",
    "jpeg", "heic", "heif", "hif", "png", "tif", "tiff",
];

pub(crate) fn read_tags(path: &Path) -> Result<Value> {
    let mut tags = original_tags(path)
        .with_context(|| format!("reading native metadata {}", path.display()))?;
    for sidecar in crate::media::sidecars(path)? {
        let meta = XmpMeta::from_str(
            &fs::read_to_string(&sidecar)
                .with_context(|| format!("reading {}", sidecar.display()))?,
        )
        .with_context(|| format!("parsing XMP {}", sidecar.display()))?;
        merge_xmp(&mut tags, &meta);
    }
    if let Some(id) = crate::identity::sidecar_photo_id(path)? {
        tags.insert(
            "XMP:Identifier".into(),
            json!(format!("https://keeps.photos/photo/{id}")),
        );
    }
    Ok(Value::Object(tags))
}

pub(crate) fn embedded_photo_id(path: &Path) -> Result<Option<String>> {
    let tags = if path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("xmp"))
    {
        let mut tags = Map::new();
        merge_xmp(&mut tags, &XmpMeta::from_str(&fs::read_to_string(path)?)?);
        tags
    } else {
        original_tags(path)?
    };
    Ok(
        crate::identity::identifier_photo_id(tags.get("XMP:Identifier").unwrap_or(&Value::Null))
            .or_else(|| {
                tags.get("XMP:PhotoID")
                    .and_then(Value::as_str)
                    .and_then(crate::identity::normalize)
            }),
    )
}

fn original_tags(path: &Path) -> Result<Map<String, Value>> {
    if crate::media::is_video(path) {
        let tags = crate::video_metadata::read_tags(path)?;
        return tags
            .as_object()
            .cloned()
            .context("video metadata must be an object");
    }
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    ensure!(
        SUPPORTED.contains(&ext.as_str()),
        "unsupported native metadata format: {ext}"
    );
    let mut input = BufReader::new(File::open(path)?);
    let mut tags = Map::new();
    if ext == "cr3" {
        let metadata = exif::experimental::read_cr3_metadata(&mut input)?;
        map_fields(&mut tags, &metadata.fields)?;
        if let Some(id) = metadata.image_unique_id()? {
            tags.entry("MakerNotes:ImageUniqueID").or_insert(json!(id));
        }
    } else if ["crw", "raw"].contains(&ext.as_str()) {
        let metadata = exif::experimental::read_legacy_raw_metadata(&mut input)?;
        for (key, value) in [
            ("EXIF:Make", metadata.make),
            ("EXIF:Model", metadata.model),
            ("EXIF:DateTimeOriginal", metadata.capture_time),
        ] {
            if let Some(value) = value {
                tags.insert(key.into(), json!(value));
            }
        }
        if let Some(timestamp) = metadata.capture_timestamp {
            let date = chrono::DateTime::from_timestamp(i64::from(timestamp), 0)
                .context("invalid CIFF capture timestamp")?;
            let mut text = date.format("%Y:%m:%d %H:%M:%S").to_string();
            if let Some(offset) = metadata.timezone_offset_seconds {
                let zone =
                    chrono::FixedOffset::east_opt(offset).context("invalid CIFF timezone")?;
                text.push_str(&zone.to_string());
            }
            tags.insert("EXIF:DateTimeOriginal".into(), json!(text));
        }
        if let Some(size) = metadata.dimensions {
            dimensions(&mut tags, size);
        }
    } else {
        let exif = match exif::Reader::new().read_from_container(&mut input) {
            Ok(exif) => Some(exif),
            Err(exif::Error::NotFound(_)) => None,
            Err(error) => return Err(error.into()),
        };
        if let Some(exif) = exif {
            let fields: Vec<_> = exif
                .fields()
                .filter(|f| f.ifd_num == In::PRIMARY)
                .cloned()
                .collect();
            map_fields(&mut tags, &fields)?;
            if ext == "dcr"
                && let Some(field) = fields
                    .iter()
                    .find(|f| f.tag == Tag(exif::Context::Tiff, 0x9003))
                && let exif::Value::Ascii(values) = &field.value
                && let Some(value) = values.first()
            {
                tags.insert(
                    "EXIF:DateTimeOriginal".into(),
                    json!(
                        std::str::from_utf8(value)?
                            .trim_matches(|c: char| c == '\0' || c.is_whitespace())
                    ),
                );
            }
            if let Some(id) = exif.image_unique_id(In::PRIMARY)? {
                tags.entry("MakerNotes:ImageUniqueID").or_insert(json!(id));
            }
            if let Some(lens) = exif.lens_model(In::PRIMARY)? {
                tags.entry("EXIF:LensModel").or_insert(json!(lens));
            }
            let children = exif.sub_ifds(In::PRIMARY)?;
            let full: Vec<_> = children
                .iter()
                .filter(|fields| {
                    uint(fields, Tag(exif::Context::Tiff, 254)).is_some_and(|v| v & 1 == 0)
                })
                .filter_map(|f| field_dimensions(f))
                .collect();
            if full.len() == 1 {
                dimensions(&mut tags, full[0]);
            } else if ext == "iiq"
                && let (Some(width), Some(height)) = (
                    uint(&fields, Tag::PixelXDimension),
                    uint(&fields, Tag::PixelYDimension),
                )
            {
                dimensions(&mut tags, (width, height));
            }
        }
    }
    input.seek(SeekFrom::Start(0))?;
    match ext.as_str() {
        "heic" | "heif" | "hif" => dimensions(
            &mut tags,
            exif::experimental::get_heif_primary_image_dimensions(&mut input)?,
        ),
        "raf" | "rw2" | "rwl" => {
            let size = exif::experimental::read_raw_dimensions(&mut input)?;
            dimensions(
                &mut tags,
                size.cropped
                    .or(size.full)
                    .context("RAW container has no image dimensions")?,
            );
        }
        "png" => dimensions(&mut tags, png_dimensions(&mut input)?),
        "jpg" | "jpeg" => dimensions(&mut tags, jpeg_dimensions(&mut input)?),
        _ => {}
    }
    if ["png", "heic", "heif", "hif"].contains(&ext.as_str()) {
        let mut file = XmpFile::new()?;
        file.open_file(path, OpenFileOptions::default().for_read().only_xmp())
            .with_context(|| format!("opening Adobe metadata {}", path.display()))?;
        if let Some(meta) = file.xmp() {
            merge_xmp(&mut tags, &meta);
        }
    }
    if ["jpg", "jpeg"].contains(&ext.as_str()) {
        input.seek(SeekFrom::Start(0))?;
        for meta in jpeg_xmp(&mut input)? {
            merge_xmp(&mut tags, &meta);
        }
    }
    if ["jpg", "jpeg", "tif", "tiff"].contains(&ext.as_str()) {
        let mut file = XmpFile::new()?;
        file.open_file(path, OpenFileOptions::default().for_read())
            .context("reading legacy IPTC metadata")?;
        if let Some(meta) = file.xmp()
            && let Some(value) = meta.property("http://ns.adobe.com/photoshop/1.0/", "Urgency")
        {
            tags.insert("IPTC:Urgency".into(), json!(value.value));
        }
    }
    composite_date(&mut tags);
    Ok(tags)
}

fn uint(fields: &[Field], tag: Tag) -> Option<u32> {
    fields
        .iter()
        .find(|f| f.tag == tag)
        .and_then(|f| f.value.get_uint(0))
}
fn field_dimensions(fields: &[Field]) -> Option<(u32, u32)> {
    Some((
        uint(fields, Tag::ImageWidth)?,
        uint(fields, Tag::ImageLength)?,
    ))
}
fn dimensions(tags: &mut Map<String, Value>, size: (u32, u32)) {
    tags.insert("File:ImageWidth".into(), json!(size.0));
    tags.insert("File:ImageHeight".into(), json!(size.1));
}

fn map_fields(tags: &mut Map<String, Value>, fields: &[Field]) -> Result<()> {
    for field in fields {
        if field.tag == Tag(exif::Context::Tiff, 700) {
            let bytes = match &field.value {
                exif::Value::Byte(v) | exif::Value::Undefined(v, _) => v.as_slice(),
                exif::Value::Ascii(v) => v.first().map(Vec::as_slice).unwrap_or_default(),
                _ => bail!("unsupported TIFF XMLPacket representation"),
            };
            let xml = std::str::from_utf8(bytes).context("invalid TIFF XMP UTF-8")?;
            merge_xmp(tags, &XmpMeta::from_str(xml).context("invalid TIFF XMP")?);
            continue;
        }
        let key = match field.tag {
            Tag::Make => "Make",
            Tag::Model => "Model",
            Tag::LensModel => "LensModel",
            Tag::BodySerialNumber => "SerialNumber",
            Tag::DateTimeOriginal => "DateTimeOriginal",
            Tag::DateTimeDigitized => "CreateDate",
            Tag::SubSecTimeOriginal => "SubSecTimeOriginal",
            Tag::OffsetTimeOriginal => "OffsetTimeOriginal",
            Tag::ImageUniqueID => "ImageUniqueID",
            Tag::ImageWidth => "ImageWidth",
            Tag::ImageLength => "ImageHeight",
            Tag::Orientation => "Orientation",
            Tag::ColorSpace => "ColorSpace",
            Tag(exif::Context::Tiff, 0x4746) => "Rating",
            _ => continue,
        };
        let value = match &field.value {
            exif::Value::Ascii(values) => values
                .first()
                .map(|v| {
                    std::str::from_utf8(v)
                        .map(|s| json!(s.trim_matches(|c: char| c == '\0' || c.is_whitespace())))
                })
                .transpose()
                .context("invalid EXIF text")?,
            _ => field.value.get_uint(0).map(|v| json!(v)),
        };
        if let Some(value) = value {
            tags.entry(format!("EXIF:{key}")).or_insert(value);
        }
    }
    Ok(())
}

fn composite_date(tags: &mut Map<String, Value>) {
    let Some(original) = tags.get("EXIF:DateTimeOriginal").and_then(Value::as_str) else {
        return;
    };
    let mut date = original.to_owned();
    if let Some(sub) = tags
        .get("EXIF:SubSecTimeOriginal")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        date.push('.');
        date.push_str(sub);
    }
    if let Some(offset) = tags
        .get("EXIF:OffsetTimeOriginal")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        date.push_str(offset);
    }
    tags.insert("Composite:SubSecDateTimeOriginal".into(), json!(date));
}

pub(crate) fn merge_xmp(tags: &mut Map<String, Value>, meta: &XmpMeta) {
    for (ns, key) in [
        (XMP, "Rating"),
        (XMP, "CreateDate"),
        (EXIF, "DateTimeOriginal"),
        (EXIF, "ImageUniqueID"),
        (MM, "DocumentID"),
        (MM, "OriginalDocumentID"),
        (MM, "InstanceID"),
        (MM, "PreservedFileName"),
        ("http://ns.adobe.com/exif/1.0/aux/", "OriginalFileName"),
        ("http://ns.adobe.com/photoshop/1.0/", "DateCreated"),
        ("http://ns.adobe.com/photoshop/1.0/", "Urgency"),
        (
            "http://ns.adobe.com/camera-raw-settings/1.0/",
            "HasSettings",
        ),
        ("https://keeps.photos/ns/1.0/", "PhotoID"),
    ] {
        if let Some(value) = meta
            .property(ns, key)
            .map(|p| p.value)
            .filter(|s| !s.is_empty())
        {
            tags.entry(format!("XMP:{key}")).or_insert(json!(value));
        }
    }
    let identifiers: Vec<_> = meta
        .property_array(XMP, "Identifier")
        .map(|p| p.value)
        .collect();
    if !identifiers.is_empty() {
        tags.entry("XMP:Identifier").or_insert(json!(identifiers));
    } else if let Some(value) = meta
        .property(XMP, "Identifier")
        .map(|p| p.value)
        .filter(|s| !s.is_empty())
    {
        tags.entry("XMP:Identifier").or_insert(json!(value));
    }
}

fn jpeg_xmp(input: &mut (impl Read + Seek)) -> Result<Vec<XmpMeta>> {
    const STANDARD: &[u8] = b"http://ns.adobe.com/xap/1.0/\0";
    const EXTENDED: &[u8] = b"http://ns.adobe.com/xmp/extension/\0";
    let mut pair = [0; 2];
    input.read_exact(&mut pair)?;
    ensure!(pair == [0xff, 0xd8], "invalid JPEG header");
    let mut metas = Vec::new();
    let mut extended = std::collections::BTreeMap::<String, Vec<(u32, u32, Vec<u8>)>>::new();
    loop {
        let mut byte = [0];
        input.read_exact(&mut byte)?;
        ensure!(byte[0] == 0xff, "invalid JPEG marker");
        while byte[0] == 0xff {
            input.read_exact(&mut byte)?;
        }
        let marker = byte[0];
        if [0xda, 0xd9].contains(&marker) {
            break;
        }
        if marker == 1 || (0xd0..=0xd7).contains(&marker) {
            continue;
        }
        input.read_exact(&mut pair)?;
        let len = u16::from_be_bytes(pair);
        ensure!(len >= 2, "invalid JPEG segment length");
        if marker != 0xe1 {
            input.seek(SeekFrom::Current(i64::from(len) - 2))?;
            continue;
        }
        let mut payload = vec![0; usize::from(len) - 2];
        input.read_exact(&mut payload)?;
        if let Some(xml) = payload.strip_prefix(STANDARD) {
            metas.push(XmpMeta::from_str(
                std::str::from_utf8(xml).context("JPEG XMP UTF-8")?,
            )?);
        } else if let Some(data) = payload.strip_prefix(EXTENDED) {
            ensure!(data.len() >= 40, "truncated extended JPEG XMP header");
            let guid = std::str::from_utf8(&data[..32])?.to_owned();
            let total = u32::from_be_bytes(data[32..36].try_into()?);
            let offset = u32::from_be_bytes(data[36..40].try_into()?);
            extended
                .entry(guid)
                .or_default()
                .push((offset, total, data[40..].to_vec()));
        }
    }
    let guid = metas.iter().find_map(|m| {
        m.property("http://ns.adobe.com/xmp/note/", "HasExtendedXMP")
            .map(|p| p.value)
    });
    if let Some(guid) = guid {
        let mut chunks = extended
            .remove(&guid)
            .context("missing referenced extended JPEG XMP")?;
        chunks.sort_by_key(|c| c.0);
        let total = chunks.first().context("empty extended JPEG XMP")?.1;
        let mut xml = Vec::new();
        for (offset, length, bytes) in chunks {
            ensure!(
                offset as usize == xml.len() && length == total,
                "inconsistent extended JPEG XMP chunks"
            );
            xml.extend_from_slice(&bytes);
            ensure!(
                xml.len() <= total as usize,
                "extended JPEG XMP exceeds declared length"
            );
        }
        ensure!(xml.len() == total as usize, "truncated extended JPEG XMP");
        metas.push(XmpMeta::from_str(
            std::str::from_utf8(&xml).context("extended JPEG XMP UTF-8")?,
        )?);
    }
    Ok(metas)
}

fn png_dimensions(input: &mut impl Read) -> Result<(u32, u32)> {
    let mut header = [0; 24];
    input.read_exact(&mut header)?;
    ensure!(
        &header[..8] == b"\x89PNG\r\n\x1a\n" && &header[12..16] == b"IHDR",
        "invalid PNG image header"
    );
    Ok((
        u32::from_be_bytes(header[16..20].try_into()?),
        u32::from_be_bytes(header[20..24].try_into()?),
    ))
}
fn jpeg_dimensions(input: &mut (impl Read + Seek)) -> Result<(u32, u32)> {
    let mut pair = [0; 2];
    input.read_exact(&mut pair)?;
    ensure!(pair == [0xff, 0xd8], "invalid JPEG header");
    loop {
        let mut byte = [0];
        input.read_exact(&mut byte)?;
        ensure!(byte[0] == 0xff, "invalid JPEG marker");
        while byte[0] == 0xff {
            input.read_exact(&mut byte)?;
        }
        let marker = byte[0];
        ensure!(
            ![0xda, 0xd9].contains(&marker),
            "JPEG has no frame dimensions"
        );
        if marker == 0x01 || (0xd0..=0xd7).contains(&marker) {
            continue;
        }
        input.read_exact(&mut pair)?;
        let length = u16::from_be_bytes(pair);
        ensure!(length >= 2, "invalid JPEG segment length");
        if [
            0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
        ]
        .contains(&marker)
        {
            ensure!(length >= 8, "truncated JPEG frame");
            let mut frame = [0; 5];
            input.read_exact(&mut frame)?;
            return Ok((
                u16::from_be_bytes([frame[3], frame[4]]) as u32,
                u16::from_be_bytes([frame[1], frame[2]]) as u32,
            ));
        }
        input.seek(SeekFrom::Current(i64::from(length) - 2))?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn standard_container_dimensions_and_truncation() -> Result<()> {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend_from_slice(&1200u32.to_be_bytes());
        png.extend_from_slice(&800u32.to_be_bytes());
        assert_eq!(png_dimensions(&mut png.as_slice())?, (1200, 800));
        assert!(png_dimensions(&mut &png[..20]).is_err());
        let jpeg = vec![
            0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc2, 0, 8, 8, 3, 32, 4, 176, 0,
        ];
        assert_eq!(jpeg_dimensions(&mut Cursor::new(&jpeg))?, (1200, 800));
        assert!(jpeg_dimensions(&mut Cursor::new(&jpeg[..14])).is_err());
        Ok(())
    }

    #[test]
    fn tiff_iptc_reconciliation_does_not_promote_rating_priority() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("rating.tif");
        let entries = [
            (256u16, 4u16, 1u32, 1u32),
            (257, 4, 1, 1),
            (258, 3, 1, 8),
            (259, 3, 1, 1),
            (262, 3, 1, 1),
            (273, 4, 1, 164),
            (277, 3, 1, 1),
            (278, 4, 1, 1),
            (279, 4, 1, 1),
            (284, 3, 1, 1),
            (0x4746, 3, 1, 4),
            (0x83bb, 1, 6, 158),
        ];
        let mut bytes = b"II".to_vec();
        bytes.extend_from_slice(&42u16.to_le_bytes());
        bytes.extend_from_slice(&8u32.to_le_bytes());
        bytes.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        for (tag, kind, count, value) in entries {
            bytes.extend_from_slice(&tag.to_le_bytes());
            bytes.extend_from_slice(&kind.to_le_bytes());
            bytes.extend_from_slice(&count.to_le_bytes());
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&[0x1c, 2, 10, 0, 1, b'3', 0]);
        fs::write(&path, &bytes)?;
        let tags = read_tags(&path)?;
        assert_eq!(tags["EXIF:Rating"], json!(4));
        assert_eq!(tags["IPTC:Urgency"], json!("3"));
        assert!(tags["XMP:Urgency"].is_null());
        assert_eq!(
            crate::media::MediaProcessor::new().extract(&path)?.rating,
            4
        );
        assert_eq!(fs::read(&path)?, bytes);
        Ok(())
    }

    #[test]
    fn dcr_ifd0_date_is_read_without_modifying_source() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("date.dcr");
        let mut bytes = b"II".to_vec();
        bytes.extend_from_slice(&42u16.to_le_bytes());
        bytes.extend_from_slice(&8u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&0x9003u16.to_le_bytes());
        bytes.extend_from_slice(&2u16.to_le_bytes());
        bytes.extend_from_slice(&20u32.to_le_bytes());
        bytes.extend_from_slice(&26u32.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(b"2017:04:14 12:34:50\0");
        fs::write(&path, &bytes)?;
        let metadata = crate::media::MediaProcessor::new().extract(&path)?;
        assert_eq!(metadata.capture_original, "2017:04:14 12:34:50");
        assert!(metadata.capture_time.is_some());
        assert_eq!(fs::read(&path)?, bytes);
        Ok(())
    }

    #[test]
    fn jpeg_standard_and_extended_xmp_preserve_actual_fields() -> Result<()> {
        fn segment(jpeg: &mut Vec<u8>, payload: &[u8]) {
            jpeg.extend_from_slice(&[0xff, 0xe1]);
            jpeg.extend_from_slice(&((payload.len() + 2) as u16).to_be_bytes());
            jpeg.extend_from_slice(payload);
        }
        let main=br#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" photoshop:Urgency="2" xmlns:xmpNote="http://ns.adobe.com/xmp/note/" xmpNote:HasExtendedXMP="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"/></rdf:RDF></x:xmpmeta>"#;
        let extended=br#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="4"/></rdf:RDF></x:xmpmeta>"#;
        let mut jpeg = vec![0xff, 0xd8];
        let mut packet = b"http://ns.adobe.com/xap/1.0/\0".to_vec();
        packet.extend_from_slice(main);
        segment(&mut jpeg, &packet);
        let missing = jpeg.clone();
        let half = extended.len() / 2;
        for (offset, part) in [(0, &extended[..half]), (half, &extended[half..])] {
            let mut packet =
                b"http://ns.adobe.com/xmp/extension/\0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_vec();
            packet.extend_from_slice(&(extended.len() as u32).to_be_bytes());
            packet.extend_from_slice(&(offset as u32).to_be_bytes());
            packet.extend_from_slice(part);
            segment(&mut jpeg, &packet);
        }
        jpeg.extend_from_slice(&[0xff, 0xda]);
        let mut tags = Map::new();
        for meta in jpeg_xmp(&mut Cursor::new(jpeg))? {
            merge_xmp(&mut tags, &meta);
        }
        assert_eq!(tags["XMP:Urgency"], json!("2"));
        assert_eq!(tags["XMP:Rating"], json!("4"));
        let mut missing = missing;
        missing.extend_from_slice(&[0xff, 0xda]);
        assert!(jpeg_xmp(&mut Cursor::new(missing)).is_err());
        Ok(())
    }

    #[test]
    fn unsupported_format_is_explicit() {
        for name in ["photo.bay", "photo.k25", "photo.ari"] {
            let error = original_tags(Path::new(name)).expect_err("unsupported format");
            assert!(
                error
                    .to_string()
                    .contains("unsupported native metadata format")
            );
        }
    }

    #[test]
    fn xmp_merge_preserves_original_value_and_identifier_array() -> Result<()> {
        let meta = XmpMeta::from_str(
            r#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="-1"><xmp:Identifier><rdf:Bag><rdf:li>third-party</rdf:li><rdf:li>https://keeps.photos/photo/11111111-1111-4111-8111-111111111111</rdf:li></rdf:Bag></xmp:Identifier></rdf:Description></rdf:RDF></x:xmpmeta>"#,
        )?;
        let mut tags = Map::new();
        merge_xmp(&mut tags, &meta);
        assert_eq!(tags["XMP:Rating"], json!("-1"));
        assert_eq!(
            crate::identity::identifier_photo_id(&tags["XMP:Identifier"]).as_deref(),
            Some("11111111-1111-4111-8111-111111111111")
        );
        tags.insert("XMP:Rating".into(), json!(4));
        merge_xmp(&mut tags, &meta);
        assert_eq!(tags["XMP:Rating"], json!(4));
        Ok(())
    }
}
