"""Parser tests for the AI reviewer's output (``review.parse_findings`` +
``review._extract_json_object``).

Regression cover for the "couldn't parse the reviewer's output: Expecting value:
line 1 column 1 (char 0)" failure: an empty reply must raise a clear error, and a
reply the model wrapped in prose/fences (despite the prompt asking for bare JSON)
must still parse rather than blow up on the leading non-JSON char.
"""

import pytest

from haro.review import _extract_json_object, parse_code_review_verdict, parse_findings


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


def test_the_last_object_wins_over_a_draft_written_before_it():
    draft = '{"summary": "draft", "findings": []}'
    final = '{"summary": "final", "findings": []}'
    text = f"First pass:\n{draft}\nOn reflection:\n{final}"
    assert _extract_json_object(text) == final
    assert parse_findings(text)[0] == "final"


def test_objects_nested_in_the_answer_are_not_taken_on_their_own():
    text = 'ok {"summary": "s", "findings": [{"file": "a", "title": "t"}]}'
    assert _extract_json_object(text) == text[3:]


def test_braces_in_prose_before_the_answer_are_skipped():
    answer = '{"summary": "s", "findings": []}'
    text = f"Use {{name}} or {{ nothing }} here. {answer}"
    assert _extract_json_object(text) == answer


def test_a_reply_with_no_object_falls_back_to_the_text():
    assert _extract_json_object("no json here") == "no json here"
    assert _extract_json_object("[1, 2]") == "[1, 2]"


def test_a_fenced_reply_still_parses():
    text = '```json\n{"summary": "s", "findings": []}\n```'
    assert parse_findings(text)[0] == "s"


def test_a_reply_cut_off_mid_answer_is_an_error_not_an_empty_review():
    text = '{"summary": "s", "findings": [{"file": "a", "title": "t"}, {"file": "b", "title": "u"}'
    with pytest.raises(ValueError):
        parse_findings(text)
    with pytest.raises(ValueError):
        parse_code_review_verdict(text)


def test_a_stray_object_after_the_answer_does_not_replace_it():
    answer = '{"summary": "real", "findings": []}'
    for tail in ("Return shape: {}", 'Example: {"ok": true}'):
        assert parse_findings(answer + "\n" + tail)[0] == "real"


def test_the_verdict_parser_takes_the_last_verdict_object():
    draft = '{"verdict": "fail", "summary": "draft", "must_fix": []}'
    final = '{"verdict": "pass", "summary": "final", "must_fix": []}'
    verdict, summary, _, _ = parse_code_review_verdict(draft + "\nOn reflection: " + final)
    assert (verdict, summary) == ("pass", "final")
