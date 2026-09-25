"""`files.resolve_tsconfig` — merged tsconfig compilerOptions for the code editor's
Monaco language service. JSONC (comments + trailing commas) must parse, the `extends`
chain must resolve parent-first (child wins), and anything escaping the worktree or
malformed must be tolerated (skipped, never raised)."""

from pathlib import Path

from haro import files


def test_none_without_config(tmp_path: Path):
    assert files.resolve_tsconfig(str(tmp_path)) is None


def test_reads_jsonc_with_comments_and_trailing_commas(tmp_path: Path):
    (tmp_path / "tsconfig.json").write_text(
        """
        {
          // line comment
          "compilerOptions": {
            "jsx": "react-jsx", /* block comment */
            "target": "ES2022",
            "strict": true,
          },
        }
        """
    )
    co = files.resolve_tsconfig(str(tmp_path))
    assert co == {"jsx": "react-jsx", "target": "ES2022", "strict": True}


def test_does_not_strip_slashes_inside_strings(tmp_path: Path):
    (tmp_path / "tsconfig.json").write_text(
        '{"compilerOptions": {"jsxImportSource": "https://esm.sh/react"}}'
    )
    co = files.resolve_tsconfig(str(tmp_path))
    assert co == {"jsxImportSource": "https://esm.sh/react"}


def test_extends_relative_child_overrides_parent(tmp_path: Path):
    (tmp_path / "tsconfig.base.json").write_text(
        '{"compilerOptions": {"target": "ES2015", "strict": false, "jsx": "react"}}'
    )
    (tmp_path / "tsconfig.json").write_text(
        '{"extends": "./tsconfig.base.json", "compilerOptions": {"target": "ESNext", "strict": true}}'
    )
    co = files.resolve_tsconfig(str(tmp_path))
    # child wins on conflicts, inherits the rest from the base
    assert co == {"target": "ESNext", "strict": True, "jsx": "react"}


def test_extends_package_in_node_modules(tmp_path: Path):
    pkg = tmp_path / "node_modules" / "@tsconfig" / "node18"
    pkg.mkdir(parents=True)
    (pkg / "tsconfig.json").write_text('{"compilerOptions": {"target": "ES2022", "module": "NodeNext"}}')
    (tmp_path / "tsconfig.json").write_text(
        '{"extends": "@tsconfig/node18", "compilerOptions": {"jsx": "react-jsx"}}'
    )
    co = files.resolve_tsconfig(str(tmp_path))
    assert co == {"target": "ES2022", "module": "NodeNext", "jsx": "react-jsx"}


def test_extends_escaping_worktree_is_skipped(tmp_path: Path):
    outside = tmp_path / "outside.json"
    outside.write_text('{"compilerOptions": {"strict": false}}')
    wt = tmp_path / "wt"
    wt.mkdir()
    (wt / "tsconfig.json").write_text(
        '{"extends": "../outside.json", "compilerOptions": {"jsx": "react-jsx"}}'
    )
    co = files.resolve_tsconfig(str(wt))
    # the out-of-worktree base is refused; only the local options survive
    assert co == {"jsx": "react-jsx"}


def test_malformed_config_is_tolerated(tmp_path: Path):
    (tmp_path / "tsconfig.json").write_text("{ this is not json ")
    assert files.resolve_tsconfig(str(tmp_path)) == {}


def test_extends_cycle_terminates(tmp_path: Path):
    (tmp_path / "a.json").write_text('{"extends": "./tsconfig.json", "compilerOptions": {"strict": true}}')
    (tmp_path / "tsconfig.json").write_text('{"extends": "./a.json", "compilerOptions": {"jsx": "react-jsx"}}')
    co = files.resolve_tsconfig(str(tmp_path))
    assert co == {"strict": True, "jsx": "react-jsx"}


def test_jsconfig_fallback(tmp_path: Path):
    (tmp_path / "jsconfig.json").write_text('{"compilerOptions": {"checkJs": true}}')
    assert files.resolve_tsconfig(str(tmp_path)) == {"checkJs": True}
