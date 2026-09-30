"""`files.read_file` — the binary / large-file guard for the code editor. A
guarded file returns empty content plus an `error` + `size`, so the UI shows a
"preview not available / download" panel instead of streaming a huge or binary
blob into Monaco."""

from pathlib import Path

from haro import files


def test_reads_plain_text(tmp_path: Path):
    (tmp_path / "a.txt").write_text("hello\nworld\n")
    r = files.read_file(str(tmp_path), "a.txt")
    assert r == {"path": "a.txt", "content": "hello\nworld\n"}


def test_large_file_is_guarded_with_size(tmp_path: Path):
    big = tmp_path / "big.txt"
    big.write_bytes(b"x" * (files._MAX_BYTES + 1))
    r = files.read_file(str(tmp_path), "big.txt")
    assert r["content"] == ""
    assert r["error"] == "file too large to edit"
    assert r["size"] == files._MAX_BYTES + 1


def test_nul_byte_is_binary(tmp_path: Path):
    # NUL byte inside otherwise-decodable bytes → still flagged binary.
    (tmp_path / "blob.bin").write_bytes(b"abc\x00def")
    r = files.read_file(str(tmp_path), "blob.bin")
    assert r["content"] == ""
    assert r["error"] == "binary file"
    assert r["size"] == 7


def test_invalid_utf8_is_binary(tmp_path: Path):
    (tmp_path / "img.dat").write_bytes(b"\x89PNG\r\n\xff\xfe\xfd")
    r = files.read_file(str(tmp_path), "img.dat")
    assert r["content"] == ""
    assert r["error"] == "binary file"
