"""Parser tests for the AI reviewer's output (``review.parse_findings`` +
``review._extract_json_object``).

Regression cover for the "couldn't parse the reviewer's output: Expecting value:
line 1 column 1 (char 0)" failure: an empty reply must raise a clear error, and a
reply the model wrapped in prose/fences (despite the prompt asking for bare JSON)
must still parse rather than blow up on the leading non-JSON char.
"""

import pytest

from haro.review import _extract_json_object, parse_findings


def test_bare_json_parses():
    summary, findings = parse_findings(
        '{"summary": "ok", "findings": [{"file": "a.py", "line": 3, '
        '"severity": "high", "category": "correctness", "title": "bug", '
        '"detail": "why"}]}'
    )
    assert summary == "ok"
    assert len(findings) == 1
    assert findings[0].file == "a.py"
    assert findings[0].line == 3
    assert findings[0].severity == "high"


def test_fenced_json_parses():
    summary, findings = parse_findings(
        '```json\n{"summary": "clean", "findings": []}\n```'
    )
    assert summary == "clean"
    assert findings == []


def test_prose_wrapped_json_parses():
    # The model prefixes/suffixes prose despite instructions — we must still
    # recover the object rather than fail at char 0.
    text = (
        "Here is my review of the diff:\n"
        '{"summary": "one issue", "findings": [{"file": "x.py", "severity": '
        '"low", "title": "t", "detail": "d"}]}\n'
        "Let me know if you need more detail."
    )
    summary, findings = parse_findings(text)
    assert summary == "one issue"
    assert len(findings) == 1
    assert findings[0].line is None


def test_braces_inside_strings_dont_fool_extractor():
    text = '{"summary": "use {json} carefully", "findings": []}'
    assert _extract_json_object("noise " + text + " tail") == text


def test_empty_reply_raises_clear_error():
    with pytest.raises(ValueError, match="empty response"):
        parse_findings("")
    with pytest.raises(ValueError, match="empty response"):
        parse_findings("   \n  ")


def test_bad_severity_falls_back_to_medium():
    _, findings = parse_findings(
        '{"summary": "s", "findings": [{"file": "a", "severity": "critical", '
        '"title": "t", "detail": "d"}]}'
    )
    assert findings[0].severity == "medium"
