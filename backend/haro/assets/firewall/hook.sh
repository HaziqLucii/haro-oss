#!/bin/sh
# haro merge firewall (backlog/merge-firewall.md §3). One script, installed into the
# repo's SHARED hooks dir ($GIT_COMMON_DIR/hooks) as both pre-push and pre-merge-commit,
# so one install governs every worktree — foreign ones included. It curls the local haro
# backend for the branch's gate verdict; a red gate exits 1 and blocks the push/merge.
#
# Failure semantics are explicit and keyed on `git config haro.strict` (bool, default
# false) — read from git config, NOT the verdict response, because the two soft-failure
# axes (backend unreachable, branch unknown to haro) must still resolve when the backend
# is down, and a down backend can't announce its own strictness:
#   * backend unreachable/timeout — default fail-OPEN (warn + allow); strict ⇒ fail-CLOSED
#     (block). Fail-open is the default so a hook can't brick merging once haro is gone
#     (the uninstall-trust kill condition); strict is the opt-in for repos that would
#     rather refuse a merge than merge unverified.
#   * verdict "unknown" (no adopted/governed workspace for this branch, or not gated yet)
#     — default warn + allow; strict ⇒ block. Under strict, only a branch haro has proven
#     green may merge.
#   * verdict "red" — always blocks, regardless of strict.
set -u

# Don't firewall ourselves: haro's own integration path (integrate's local_merge, the merge
# queue, the gate's snapshot temp-branch merges) drives git through git_ops._git, which exports
# HARO_INTERNAL=1. git passes its env down to hooks, so this lets haro's own merges/pushes
# through even under strict — otherwise the base branch reads as "unknown" and haro would block
# merging its own green work. A CONVENIENCE SEAM, NOT a security boundary: any process can set
# the var (real enforcement is the verdict oracle — haro never merges red work internally).
[ "${HARO_INTERNAL:-}" = 1 ] && exit 0

url=$(git config --get haro.url 2>/dev/null) || url=
[ -n "$url" ] || url="http://127.0.0.1:8000"
# Read strict locally so fail-closed still applies with the backend down. --type=bool
# normalizes 1/yes/on → true; any error (unset key, pre-2.15 git) leaves the fail-open default.
strict=$(git config --get --type=bool haro.strict 2>/dev/null) || strict=false
# The verdict oracle matches a PROJECT by its main-repo path, so send the primary
# worktree (first `git worktree list` row), never this (possibly foreign) worktree's dir.
repo=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -n 1)

check() {
	branch=$1
	[ -n "$branch" ] || return 0
	resp=$(curl -fsS --max-time 2 -G "$url/firewall/verdict" \
		--data-urlencode "repo=$repo" --data-urlencode "branch=$branch" 2>/dev/null) || {
		if [ "$strict" = true ]; then
			echo "haro firewall: backend unreachable — BLOCKED '$branch' ([trust] strict = fail-closed). Start haro or unset haro.strict to merge." >&2
			return 1
		fi
		echo "haro firewall: backend unreachable — allowing '$branch' (fail-open)" >&2
		return 0
	}
	case $resp in
	*'"verdict":"red"'*)
		ws=$(printf '%s' "$resp" | sed -n 's/.*"workspace_id":"\([^"]*\)".*/\1/p')
		echo "haro firewall: BLOCKED '$branch' — gate is red (workspace ${ws:-?}). Make the gate green first." >&2
		return 1 ;;
	*'"verdict":"unknown"'*)
		if [ "$strict" = true ]; then
			echo "haro firewall: BLOCKED '$branch' — unknown to haro (never adopted / not gated); [trust] strict blocks ungoverned branches. Adopt it and gate green to merge." >&2
			return 1
		fi
		echo "haro firewall: '$branch' is unknown to haro (never adopted / not gated) — allowing (warn). Adopt it in haro to enforce the gate." >&2
		return 0 ;;
	esac
	return 0
}

_zero=0000000000000000000000000000000000000000

# Which governed branches does commit $1 arrive as? A merge/reset that moves a ref to
# an EXISTING branch's tip is the case we must catch; a fresh commit is nobody's tip and
# yields nothing, which is what keeps this from curling on every ordinary commit.
# $2 (optional) is a ref name to exclude — the one being updated.
candidates() {
	git branch --points-at "$1" --format='%(refname:short)' 2>/dev/null |
		while read -r b; do
			[ -n "$b" ] || continue
			[ "$b" = "${2:-}" ] && continue
			printf '%s\n' "$b"
		done
}

case $(basename "$0") in
pre-push)
	# stdin: <local ref> <local sha> <remote ref> <remote sha>; skip branch deletions (zero sha).
	rc=0
	while read -r localref localsha _remoteref _remotesha; do
		case $localref in refs/heads/*)
			[ "$localsha" = "$_zero" ] || check "${localref#refs/heads/}" || rc=1 ;;
		esac
	done
	exit $rc ;;
reference-transaction)
	# THE FAST-FORWARD HOLE (backlog/merge-firewall.md §5). git does not run
	# pre-merge-commit for a fast-forward, so `git merge <red-branch>` used to land red
	# work with exit 0 and no hook output at all — and fast-forward is the DEFAULT shape
	# for a branch cut from current main. This hook fires on the ref update itself, so it
	# catches ff-merges, `reset --hard <branch>`, and anything else that moves a branch
	# onto another branch's tip.
	#
	# Only the "prepared" state can abort the transaction (git then reports
	# "update aborted by the reference-transaction hook"); "preparing"/"committed"/
	# "aborted" are informational and must fall through, or we'd double-check and
	# double-report every update.
	[ "${1:-}" = prepared ] || exit 0
	rc=0
	while read -r old new ref; do
		case $ref in refs/heads/*) ;; *) continue ;; esac
		# Creations and deletions carry no incoming *branch* to judge.
		[ "$old" = "$_zero" ] && continue
		[ "$new" = "$_zero" ] && continue
		# An ordinary commit produces a SHA no other branch points at ⇒ no candidates ⇒
		# not one backend call. Only an arriving branch tip reaches `check`.
		for b in $(candidates "$new" "${ref#refs/heads/}"); do
			check "$b" || rc=1
		done
	done
	exit $rc ;;
*)
	# pre-merge-commit. Judge the branch being merged IN, not the one being merged INTO:
	# `git symbolic-ref HEAD` is the *target* (usually the base branch, which no workspace
	# owns), so asking about it answered the wrong question entirely — it only ever blocked
	# because `strict` refuses ungoverned branches.
	#
	# git exports GITHEAD_<sha>=<ref> for each ref being merged. That, not MERGE_HEAD, is
	# what identifies the source here: .git/MERGE_HEAD is NOT yet written when
	# pre-merge-commit runs on a clean auto-merge (verified against git 2.x).
	rc=0
	found=0
	for b in $(env | sed -n 's/^GITHEAD_[0-9a-fA-F]*=//p'); do
		found=1
		check "${b#refs/heads/}" || rc=1
	done
	[ "$found" = 1 ] && exit $rc
	# Nothing named the source (an unusual merge driver): try MERGE_HEAD, then fall back to
	# the target branch so `strict` still has something to refuse rather than silently allowing.
	incoming=$(git rev-parse --quiet --verify MERGE_HEAD 2>/dev/null || true)
	if [ -n "$incoming" ]; then
		for b in $(candidates "$incoming"); do
			found=1
			check "$b" || rc=1
		done
		[ "$found" = 1 ] && exit $rc
	fi
	check "$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || exit 1 ;;
esac
