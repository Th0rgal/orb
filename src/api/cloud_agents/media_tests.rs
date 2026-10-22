use super::*;
use std::fs;

/// PNG signature + IHDR for a 640x320 image.
const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\x02\x80\0\0\x01\x40\x08\x02\0\0\0body";
const PDF: &[u8] = b"%PDF-1.7\nfake";
const MISSION: Uuid = Uuid::from_u128(0x55518e2b_ba20_42bc_b5d8_bbdb3b072328);

/// A fake Hermes namespace: `<ns>/tmp`, `<ns>/var/lib/hermes/cache/...` and a
/// separate Core working dir.
struct Env {
    _dir: tempfile::TempDir,
    ns: PathBuf,
    work: PathBuf,
    source: MediaSource,
}

fn env() -> Env {
    let dir = tempfile::tempdir().unwrap();
    let ns = dir.path().join("ns");
    let work = dir.path().join("work");
    fs::create_dir_all(ns.join("tmp")).unwrap();
    fs::create_dir_all(ns.join("var/lib/hermes/cache/images")).unwrap();
    fs::create_dir_all(ns.join("etc")).unwrap();
    fs::create_dir_all(&work).unwrap();
    fs::write(ns.join("etc/passwd"), "root:x:0:0").unwrap();
    fs::write(
        ns.join("var/lib/hermes/cache/bws_cache.json"),
        "{\"token\":1}",
    )
    .unwrap();
    fs::write(ns.join("var/lib/hermes/cache/model_catalog.json"), "{}").unwrap();
    let source = MediaSource {
        namespace_root: ns.clone(),
        hermes_home: PathBuf::from("/var/lib/hermes"),
    };
    Env {
        _dir: dir,
        ns,
        work,
        source,
    }
}

impl Env {
    fn run(&self, text: &str) -> Normalized {
        normalize_text(text, Some(&self.source), &self.work, MISSION)
    }
    fn stored(&self) -> Vec<String> {
        let mut v: Vec<_> = fs::read_dir(mission_media_dir(&self.work, MISSION))
            .map(|d| {
                d.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        v.sort();
        v
    }
}

fn paths(text: &str) -> Vec<String> {
    find_media_tags(text).into_iter().map(|t| t.path).collect()
}

/// Real prod message (mission 55518e2b, event 4697674), prose trimmed.
const PROD: &str = "Un détail de routage : le modèle enregistré gemini-4-argon est en réalité servi par l’upstream gemini-4-argon-eap.\n\nMEDIA:/tmp/orb_usage_30d.png\n";

#[test]
fn finds_directives_like_hermes() {
    assert_eq!(paths(PROD), ["/tmp/orb_usage_30d.png"]);
    assert_eq!(
        paths("a MEDIA:/tmp/a.png and **MEDIA:/tmp/b.pdf**, then MEDIA: \"/tmp/c d.csv\"."),
        ["/tmp/a.png", "/tmp/b.pdf", "/tmp/c d.csv"]
    );
    assert_eq!(
        paths("MEDIA:/tmp/a.pngMEDIA:/tmp/b.png"),
        ["/tmp/a.png", "/tmp/b.png"]
    );
    assert_eq!(paths("See MEDIA:/tmp/report.pdf."), ["/tmp/report.pdf"]);
    assert_eq!(paths("(MEDIA:/tmp/x.png)"), ["/tmp/x.png"]);
}

#[test]
fn code_is_documentation_not_delivery() {
    assert!(paths("```\nMEDIA:/tmp/a.png\n```\n").is_empty());
    assert!(paths("Write `MEDIA:/tmp/a.png` to attach.").is_empty());
    assert!(paths("no path MEDIA: here, SOCIALMEDIA:/tmp/x.png").is_empty());
}

#[test]
fn prod_message_becomes_an_inline_image() {
    let e = env();
    fs::write(e.ns.join("tmp/orb_usage_30d.png"), PNG).unwrap();
    let n = e.run(PROD);
    assert!(!n.text.contains("MEDIA:"), "{}", n.text);
    let hash = hex::encode(Sha256::digest(PNG));
    let stored = mission_media_dir(&e.work, MISSION).join(format!("{hash}.png"));
    assert!(n.text.contains(&format!(
        "<image path=\"{}\" alt=\"orb_usage_30d.png\" />",
        stored.display()
    )));
    assert!(n.text.starts_with("Un détail de routage"));
    assert_eq!(n.shared_files.len(), 1);
    let f = &n.shared_files[0];
    assert_eq!(f.content_type, "image/png");
    assert_eq!(f.size_bytes, Some(PNG.len() as u64));
    assert!(f.url.ends_with(&format!("&mission_id={MISSION}")));
    assert_eq!(fs::read(&stored).unwrap(), PNG);
    // Idempotent: nothing left to rewrite.
    assert_eq!(e.run(&n.text).text, n.text);
}

#[test]
fn several_files_and_types_dedupe_by_content() {
    let e = env();
    fs::write(e.ns.join("tmp/a.png"), PNG).unwrap();
    fs::write(e.ns.join("tmp/copy.png"), PNG).unwrap();
    fs::write(e.ns.join("tmp/r.pdf"), PDF).unwrap();
    fs::write(e.ns.join("tmp/data.csv"), "a,b\n1,2\n").unwrap();
    fs::write(e.ns.join("var/lib/hermes/cache/images/gen.png"), PNG).unwrap();
    let n = e.run("MEDIA:/tmp/a.png\nMEDIA:/tmp/copy.png\nMEDIA:/tmp/r.pdf\nMEDIA:/tmp/data.csv\nMEDIA:/var/lib/hermes/cache/images/gen.png");
    assert_eq!(n.text.matches("<image ").count(), 3);
    assert_eq!(n.text.matches("<file ").count(), 2);
    assert!(!n.text.contains("unavailable"));
    // Same bytes stored once; one shared file per stored file.
    assert_eq!(e.stored().len(), 3);
    assert_eq!(n.shared_files.len(), 3);
}

#[test]
fn missing_file_becomes_unavailable_chip() {
    let e = env();
    let n = e.run("Chart:\nMEDIA:/tmp/gone.png");
    assert_eq!(
        n.text,
        "Chart:\n<file path=\"/tmp/gone.png\" name=\"gone.png\" unavailable=\"true\" />"
    );
    assert!(n.shared_files.is_empty());
    // Without Hermes's namespace nothing is read.
    let n = normalize_text("MEDIA:/tmp/a.png", None, &e.work, MISSION);
    assert!(n.text.contains("unavailable=\"true\""));
}

fn rejected(e: &Env, text: &str) {
    let n = e.run(text);
    assert!(
        n.text.contains("unavailable=\"true\""),
        "{text} -> {}",
        n.text
    );
    assert!(n.shared_files.is_empty(), "{text}");
    assert!(e.stored().is_empty(), "{text}");
}

#[test]
fn only_hermes_output_directories_are_read() {
    let e = env();
    fs::write(e.ns.join("etc/hosts.txt"), "x").unwrap();
    rejected(&e, "MEDIA:/etc/hosts.txt");
    rejected(&e, "MEDIA:/etc/passwd");
    rejected(&e, "MEDIA:/var/lib/hermes/cache/bws_cache.json");
    rejected(&e, "MEDIA:/var/lib/hermes/cache/model_catalog.json");
    rejected(&e, "MEDIA:/root/.ssh/id_rsa");
    rejected(&e, "MEDIA:~/notes.txt");
    rejected(&e, "MEDIA:/tmp");
}

#[test]
fn traversal_is_rejected() {
    let e = env();
    fs::write(e.ns.join("etc/x.txt"), "secret").unwrap();
    rejected(&e, "MEDIA:/tmp/../etc/x.txt");
    rejected(&e, "MEDIA:/tmp/./../etc/x.txt");
    rejected(&e, "MEDIA:/tmp//x.txt");
    rejected(&e, "MEDIA:/var/lib/hermes/cache/images/../bws_cache.json");
}

#[test]
fn symlinks_and_hard_links_are_rejected() {
    let e = env();
    fs::write(e.ns.join("etc/x.png"), PNG).unwrap();
    std::os::unix::fs::symlink(e.ns.join("etc/x.png"), e.ns.join("tmp/link.png")).unwrap();
    rejected(&e, "MEDIA:/tmp/link.png");
    std::os::unix::fs::symlink(e.ns.join("etc"), e.ns.join("tmp/dir")).unwrap();
    rejected(&e, "MEDIA:/tmp/dir/x.png");
    fs::hard_link(e.ns.join("etc/x.png"), e.ns.join("tmp/hard.png")).unwrap();
    rejected(&e, "MEDIA:/tmp/hard.png");
}

#[test]
fn secrets_hidden_files_and_special_files_are_rejected() {
    let e = env();
    for name in [
        "api_token.txt",
        ".env.txt",
        "credentials.json",
        "id_rsa.txt",
    ] {
        fs::write(e.ns.join("tmp").join(name), "x").unwrap();
        rejected(&e, &format!("MEDIA:/tmp/{name}"));
    }
    fs::write(e.ns.join("tmp/key.pem"), "x").unwrap();
    rejected(&e, "MEDIA:/tmp/key.pem");
    let fifo = CString::new(e.ns.join("tmp/pipe.txt").to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    rejected(&e, "MEDIA:/tmp/pipe.txt");
    fs::create_dir(e.ns.join("tmp/folder.png")).unwrap();
    rejected(&e, "MEDIA:/tmp/folder.png");
}

#[test]
fn size_bombs_are_rejected() {
    let e = env();
    let f = fs::File::create(e.ns.join("tmp/huge.png")).unwrap();
    f.set_len(MAX_FILE_BYTES + 1).unwrap();
    rejected(&e, "MEDIA:/tmp/huge.png");
    fs::write(e.ns.join("tmp/empty.png"), b"").unwrap();
    rejected(&e, "MEDIA:/tmp/empty.png");
}

#[test]
fn per_message_cap() {
    let e = env();
    let mut text = String::new();
    for i in 0..MAX_FILES_PER_MESSAGE + 2 {
        fs::write(e.ns.join(format!("tmp/{i}.txt")), format!("{i}")).unwrap();
        text.push_str(&format!("MEDIA:/tmp/{i}.txt\n"));
    }
    let n = e.run(&text);
    assert_eq!(n.shared_files.len(), MAX_FILES_PER_MESSAGE);
    assert_eq!(n.text.matches("unavailable=\"true\"").count(), 2);
}

#[test]
fn content_decides_the_stored_type() {
    let e = env();
    // MIME spoofing: a PDF named .png is refused, not served as an image.
    fs::write(e.ns.join("tmp/fake.png"), PDF).unwrap();
    rejected(&e, "MEDIA:/tmp/fake.png");
    fs::write(e.ns.join("tmp/bin.csv"), b"a,\0b").unwrap();
    rejected(&e, "MEDIA:/tmp/bin.csv");
    fs::write(e.ns.join("tmp/x.exe"), b"MZ").unwrap();
    rejected(&e, "MEDIA:/tmp/x.exe");
    // A PNG named .jpg is stored as what it is.
    fs::write(e.ns.join("tmp/photo.jpg"), PNG).unwrap();
    let n = e.run("MEDIA:/tmp/photo.jpg");
    assert_eq!(n.shared_files[0].content_type, "image/png");
    assert!(e.stored()[0].ends_with(".png"));
    // Active content is stored as text, never as HTML/SVG.
    fs::write(e.ns.join("tmp/page.html"), "<script>alert(1)</script>").unwrap();
    fs::write(e.ns.join("tmp/pic.svg"), "<svg onload=alert(1)/>").unwrap();
    let n = e.run("MEDIA:/tmp/page.html MEDIA:/tmp/pic.svg");
    assert!(n.text.matches("<file ").count() == 2 && !n.text.contains("<image"));
    assert!(n
        .shared_files
        .iter()
        .all(|f| f.content_type.starts_with("text/plain")));
}

#[test]
fn generated_attributes_cannot_break_out() {
    let e = env();
    let n = e.run("MEDIA:`/tmp/a\"><script>.png`");
    assert!(!n.text.contains("<script>"), "{}", n.text);
}

#[test]
fn store_paths_are_parsed_strictly() {
    let work = Path::new("/srv/work");
    let root = media_root(work);
    let h = "a".repeat(64);
    let ok = format!("{}/{MISSION}/{h}.png", root.display());
    let (m, p, mime) = parse_store_path(work, &ok).unwrap().unwrap();
    assert_eq!((m, mime), (MISSION, "image/png"));
    assert_eq!(p, PathBuf::from(&ok));
    for bad in [
        format!("{}/{MISSION}/../{h}.png", root.display()),
        format!("{}/{MISSION}/{}.png", root.display(), "A".repeat(64)),
        format!("{}/{MISSION}/{h}.html", root.display()),
        format!("{}/{MISSION}/x/{h}.png", root.display()),
        format!("{}/not-a-uuid/{h}.png", root.display()),
        format!("{}/{MISSION}", root.display()),
    ] {
        assert!(parse_store_path(work, &bad).unwrap().is_err(), "{bad}");
    }
    assert!(parse_store_path(work, "/srv/work/other/x.png").is_none());
}

/// The shared client fixture: every MEDIA case finds the same paths in Core.
#[test]
fn shared_fixture_media_cases_agree() {
    let raw = include_str!("../../../shared/orb-spec/file-references.json");
    let spec: Value = serde_json::from_str(raw).unwrap();
    let mut checked = 0;
    for case in spec["cases"].as_array().unwrap() {
        let input = case["input"].as_str().unwrap();
        if !input.contains("MEDIA:") {
            continue;
        }
        let expected: Vec<String> = case["refs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["path"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(paths(input), expected, "{}", case["name"]);
        checked += 1;
    }
    assert!(checked >= 3);
}

#[test]
fn agent_writable_root_directories_cannot_be_symlinks() {
    let e = env();
    fs::write(e.ns.join("etc/hosts.txt"), "127.0.0.1").unwrap();
    std::os::unix::fs::symlink(
        e.ns.join("etc"),
        e.ns.join("var/lib/hermes/cache/generated"),
    )
    .unwrap();
    rejected(&e, "MEDIA:/var/lib/hermes/cache/generated/hosts.txt");
    // The operator-owned base (HERMES_HOME) may itself be a symlink.
    let real = e.ns.join("srv/hermes");
    fs::create_dir_all(real.join("cache/images")).unwrap();
    fs::write(real.join("cache/images/p.png"), PNG).unwrap();
    let source = MediaSource {
        namespace_root: e.ns.clone(),
        hermes_home: PathBuf::from("/var/lib/linked"),
    };
    std::os::unix::fs::symlink(&real, e.ns.join("var/lib/linked")).unwrap();
    let n = normalize_text(
        "MEDIA:/var/lib/linked/cache/images/p.png",
        Some(&source),
        &e.work,
        MISSION,
    );
    assert_eq!(n.shared_files.len(), 1, "{}", n.text);
}

#[test]
fn decompression_bombs_are_rejected() {
    let e = env();
    // 100000 x 100000 pixels in a few bytes.
    let bomb = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\x01\x86\xa0\0\x01\x86\xa0\x08\x02\0\0\0";
    fs::write(e.ns.join("tmp/bomb.png"), bomb).unwrap();
    rejected(&e, "MEDIA:/tmp/bomb.png");
    let jpeg = b"\xFF\xD8\xFF\xE0\0\x04ab\xFF\xC0\0\x11\x08\x01\x40\x02\x80\x03rest-of-frame";
    assert_eq!(image_dimensions(jpeg), Some((640, 320)));
    assert_eq!(image_dimensions(PNG), Some((640, 320)));
    assert_eq!(
        image_dimensions(b"GIF89a\x80\x02\x40\x01"),
        Some((640, 320))
    );
}
