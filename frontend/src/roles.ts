// Pure helpers for the composer's role strip (notes/workflow-roles-plan.md): when
// `[roles] enabled`, the composer swaps its model/effort pickers for a strip
// showing each step's configured model/effort, with the step THIS submit will
// run highlighted. No React/DOM here so App.tsx can stay the only place that
// touches state.

import type { RolesConfig } from "./types";

export type RoleStep = "plan" | "build" | "review";

// Which step a submit will run, given the composer's "Plan first" toggle. Mirrors
// backend main.py's `role_name = req.role or ("plan" if req.plan else "build")`.
export function nextRole(planFirst: boolean): "plan" | "build" {
  return planFirst ? "plan" : "build";
}

// A role's "model:effort" shorthand as the strip's label — "fable · xhigh",
// "haiku" (scout has no effort), or "not set" for an empty/unconfigured role (so
// the strip never renders a bare dangling "·").
export function roleLabel(shorthand: string): string {
  if (!shorthand) return "not set";
  const [model, effort] = shorthand.split(":");
  return effort ? `${model} · ${effort}` : model;
}

// Resolve the composer's picked backend + model/effort into startAgent args. Local:
// pass the model tag (no effort). Claude: "default" → omit the flag so the CLI uses
// its own configured default.
//
// `rolesEnabled` short-circuits to omitting model/effort entirely (and forces the
// claude-code adapter): when `[roles]` is on, the composer shows the role strip
// instead of these pickers, so `model`/`effort` here are just STALE leftover picker
// state — sending them would silently re-open the "approve a plan, build at the
// plan's model" trap `[roles]` exists to close (main.py's `req.model or role.model
// or ...` always takes an explicit `req.model` first). Roles resolve model/effort
// server-side per this run's step instead.
export function runArgs(o: {
  model: string;
  effort: string;
  backend: string;
  localModel: string;
  rolesEnabled?: boolean;
}): {
  adapter: string;
  model: string | undefined;
  effort: string | undefined;
} {
  if (o.rolesEnabled) return { adapter: "claude-code", model: undefined, effort: undefined };
  if (o.backend === "local")
    return { adapter: "local", model: o.localModel || undefined, effort: undefined };
  return {
    adapter: "claude-code",
    model: o.model === "default" ? undefined : o.model,
    effort: o.effort === "default" ? undefined : o.effort,
  };
}

export interface RoleStripStep {
  step: RoleStep;
  label: string;
  active: boolean; // true for the step this submit will run
}

// The strip's ordered steps: plan › build › review, each labeled from the
// project's `[roles]` config, with the step this submit will run highlighted.
// Review never highlights here — Phase 3's refuter runs on the gate, not a
// composer submit.
export function stripSteps(cfg: RolesConfig, planFirst: boolean): RoleStripStep[] {
  const next = nextRole(planFirst);
  return [
    { step: "plan", label: roleLabel(cfg.plan), active: next === "plan" },
    { step: "build", label: roleLabel(cfg.build), active: next === "build" },
    { step: "review", label: roleLabel(cfg.review), active: false },
  ];
}
