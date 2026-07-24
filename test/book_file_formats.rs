use std::io::{Cursor, Write};

use rust_lib_velora::api::book_file::{open_book_bytes, read_book_chapter_bytes};
use zip::write::SimpleFileOptions;

#[test]
fn txt_book_detects_chinese_chapters() {
    let bytes = "第1章 风起\n纸页翻动。\n第2章 灯下\n继续阅读。"
        .as_bytes()
        .to_vec();
    let meta = open_book_bytes(
        "fixture.txt".to_string(),
        "fixture.txt".to_string(),
        bytes.clone(),
    )
    .unwrap();
    assert_eq!(meta.format, "txt");
    assert_eq!(meta.chapters.len(), 2);
    assert_eq!(meta.chapters[0].title, "第1章 风起");
    let content = read_book_chapter_bytes(
        "fixture.txt".to_string(),
        "fixture.txt".to_string(),
        bytes,
        meta.chapters[0].start,
        meta.chapters[0].end,
    )
    .unwrap();
    assert!(content.contains("纸页翻动"));
}

#[test]
fn epub_book_reads_spine_documents() {
    let bytes = make_epub();
    let meta = open_book_bytes(
        "fixture.epub".to_string(),
        "fixture.epub".to_string(),
        bytes.clone(),
    )
    .unwrap();
    assert_eq!(meta.format, "epub");
    assert_eq!(meta.title, "测试 EPUB");
    assert_eq!(meta.author, "Velora");
    assert_eq!(meta.chapters.len(), 2);
    assert_eq!(meta.chapters[0].title, "第1章 起始");
    let chapter = read_book_chapter_bytes(
        "fixture.epub".to_string(),
        "fixture.epub".to_string(),
        bytes,
        meta.chapters[1].start,
        meta.chapters[1].end,
    )
    .unwrap();
    assert!(chapter.contains("第二章正文"));
}

#[test]
fn mobi_book_reads_uncompressed_text_record() {
    let bytes = make_mobi();
    let meta = open_book_bytes(
        "fixture.mobi".to_string(),
        "fixture.mobi".to_string(),
        bytes.clone(),
    )
    .unwrap();
    assert_eq!(meta.format, "mobi");
    assert_eq!(meta.title, "测试 MOBI");
    assert!(!meta.chapters.is_empty());
    let text = read_book_chapter_bytes(
        "fixture.mobi".to_string(),
        "fixture.mobi".to_string(),
        bytes,
        meta.chapters[0].start,
        meta.chapters[0].end,
    )
    .unwrap();
    assert!(text.contains("Hello MOBI"));
}

#[test]
fn txt_book_without_chapter_headers_falls_back_to_single_chapter() {
    let bytes = "没有章节标题，只有连续正文。\n继续阅读，应该自动回退成单章。"
        .as_bytes()
        .to_vec();
    let meta = open_book_bytes("plain.txt".to_string(), "plain.txt".to_string(), bytes).unwrap();
    assert_eq!(meta.format, "txt");
    assert_eq!(meta.chapters.len(), 1);
    assert!(!meta.chapters[0].title.is_empty());
}

#[test]
fn epub_book_preserves_first_chapter_text_range() {
    let bytes = make_epub();
    let meta = open_book_bytes(
        "fixture.epub".to_string(),
        "fixture.epub".to_string(),
        bytes.clone(),
    )
    .unwrap();
    let chapter = read_book_chapter_bytes(
        "fixture.epub".to_string(),
        "fixture.epub".to_string(),
        bytes,
        meta.chapters[0].start,
        meta.chapters[0].end,
    )
    .unwrap();
    assert!(chapter.contains("第一章正文"));
    assert!(!chapter.contains("第二章正文"));
}

#[test]
fn markdown_preserves_markup_latex_and_heading_chapters() {
    let bytes = b"---\ntitle: Formula Notes\nauthor: Ada\n---\n# Algebra\nInline $x^2$\n\n$$\n\\int_0^1 x dx\n$$\n## Geometry\n![plot](plot.png)\n".to_vec();
    let meta = open_book_bytes(
        "notes.md".to_string(),
        "notes.md".to_string(),
        bytes.clone(),
    )
    .unwrap();
    assert_eq!(meta.format, "markdown");
    assert_eq!(meta.title, "Formula Notes");
    assert_eq!(meta.author, "Ada");
    assert_eq!(meta.chapters.len(), 3);
    let algebra = read_book_chapter_bytes(
        "notes.md".to_string(),
        "notes.md".to_string(),
        bytes,
        meta.chapters[1].start,
        meta.chapters[1].end,
    )
    .unwrap();
    assert!(algebra.contains("$x^2$"));
    assert!(algebra.contains("\\int_0^1"));
    assert!(!algebra.contains("Geometry"));
}

#[test]
fn cbz_pages_are_naturally_sorted_and_read_lazily() {
    let bytes = make_cbz();
    let meta = open_book_bytes(
        "comic.cbz".to_string(),
        "comic.cbz".to_string(),
        bytes.clone(),
    )
    .unwrap();
    assert_eq!(meta.format, "cbz");
    assert_eq!(meta.chapters.len(), 2);
    assert_eq!(meta.chapters[0].title, "page2");
    assert_eq!(meta.chapters[1].title, "page10");
    let page = read_book_chapter_bytes(
        "comic.cbz".to_string(),
        "comic.cbz".to_string(),
        bytes,
        meta.chapters[0].start,
        meta.chapters[0].end,
    )
    .unwrap();
    assert_eq!(page, "data:image/jpeg;base64,cGFnZS10d28=");
}

#[test]
fn local_audio_is_exposed_as_one_playable_chapter() {
    let meta = open_book_bytes(
        "chapter.mp3".to_string(),
        "chapter.mp3".to_string(),
        vec![0x49, 0x44, 0x33],
    )
    .unwrap();
    assert_eq!(meta.format, "mp3");
    assert_eq!(meta.encoding, "binary");
    assert_eq!(meta.chapters.len(), 1);
}

fn make_epub() -> Vec<u8> {
    let cursor = Cursor::new(Vec::new());
    let mut zip = zip::ZipWriter::new(cursor);
    let options = SimpleFileOptions::default();
    zip.start_file("META-INF/container.xml", options).unwrap();
    zip.write_all(br#"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#).unwrap();
    zip.start_file("OPS/content.opf", options).unwrap();
    zip.write_all(r#"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>测试 EPUB</dc:title><dc:creator>Velora</dc:creator></metadata><manifest><item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>"#.as_bytes()).unwrap();
    zip.start_file("OPS/chapter1.xhtml", options).unwrap();
    zip.write_all("<html><body><h1>第1章 起始</h1><p>第一章正文。</p></body></html>".as_bytes())
        .unwrap();
    zip.start_file("OPS/chapter2.xhtml", options).unwrap();
    zip.write_all("<html><body><h1>第2章 继续</h1><p>第二章正文。</p></body></html>".as_bytes())
        .unwrap();
    zip.finish().unwrap().into_inner()
}

fn make_cbz() -> Vec<u8> {
    let cursor = Cursor::new(Vec::new());
    let mut zip = zip::ZipWriter::new(cursor);
    let options = SimpleFileOptions::default();
    zip.start_file("pages/page10.jpg", options).unwrap();
    zip.write_all(b"page-ten").unwrap();
    zip.start_file("pages/page2.jpg", options).unwrap();
    zip.write_all(b"page-two").unwrap();
    zip.finish().unwrap().into_inner()
}

fn make_mobi() -> Vec<u8> {
    let title = "测试 MOBI".as_bytes();
    let text = b"<html><body><h1>Chapter 1</h1><p>Hello MOBI</p></body></html>";
    let rec0_offset = 78 + 16;
    let mobi_header_len = 232usize;
    let rec1_offset = rec0_offset + 16 + mobi_header_len + title.len();
    let mut bytes = vec![0u8; rec1_offset];
    bytes[0..8].copy_from_slice(b"VELORA  ");
    write_u16(&mut bytes, 76, 2);
    write_u32(&mut bytes, 78, rec0_offset as u32);
    write_u32(&mut bytes, 86, rec1_offset as u32);
    write_u16(&mut bytes, rec0_offset, 1);
    write_u32(&mut bytes, rec0_offset + 4, text.len() as u32);
    write_u16(&mut bytes, rec0_offset + 8, 1);
    write_u16(&mut bytes, rec0_offset + 10, 4096);
    write_u16(&mut bytes, rec0_offset + 12, 0);
    let mobi = rec0_offset + 16;
    bytes[mobi..mobi + 4].copy_from_slice(b"MOBI");
    write_u32(&mut bytes, mobi + 4, mobi_header_len as u32);
    write_u32(&mut bytes, mobi + 28, 65001);
    write_u32(&mut bytes, mobi + 84, mobi_header_len as u32);
    write_u32(&mut bytes, mobi + 88, title.len() as u32);
    bytes[mobi + mobi_header_len..mobi + mobi_header_len + title.len()].copy_from_slice(title);
    bytes.extend_from_slice(text);
    bytes
}

fn write_u16(bytes: &mut [u8], offset: usize, value: u16) {
    bytes[offset..offset + 2].copy_from_slice(&value.to_be_bytes());
}

fn write_u32(bytes: &mut [u8], offset: usize, value: u32) {
    bytes[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
}
