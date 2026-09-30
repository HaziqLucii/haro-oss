// Tech-stack brand logos for the sidebar project rows. Unlike the affordance
// icons in icons.tsx (monochrome, stroke: currentColor so they follow the
// theme), these are multi-color BRAND marks — Shopify green, Vue green, Laravel
// coral — that would die if forced through currentColor. So we follow FileIcon's
// pattern instead: inline the real SVGs at build time via `?raw` (only the ones
// we import ship in the bundle, no network fetch) and drop them in through
// dangerouslySetInnerHTML. Framework/language marks come from the `devicon`
// set; Shopify (not in devicon) is vendored under assets/stack-logos.
//
// The `id`s here are the contract with the backend — they must match
// presets._LOGO_ORDER, which is what populates Project.stack.

import nextjs from "devicon/icons/nextjs/nextjs-original.svg?raw";
import react from "devicon/icons/react/react-original.svg?raw";
import vuejs from "devicon/icons/vuejs/vuejs-original.svg?raw";
import nuxtjs from "devicon/icons/nuxtjs/nuxtjs-original.svg?raw";
import svelte from "devicon/icons/svelte/svelte-original.svg?raw";
import angular from "devicon/icons/angular/angular-original.svg?raw";
import astro from "devicon/icons/astro/astro-original.svg?raw";
import nestjs from "devicon/icons/nestjs/nestjs-original.svg?raw";
import express from "devicon/icons/express/express-original.svg?raw";
import nodejs from "devicon/icons/nodejs/nodejs-original.svg?raw";
import laravel from "devicon/icons/laravel/laravel-original.svg?raw";
import php from "devicon/icons/php/php-original.svg?raw";
import python from "devicon/icons/python/python-original.svg?raw";
import django from "devicon/icons/django/django-plain.svg?raw";
import flask from "devicon/icons/flask/flask-original.svg?raw";
import fastapi from "devicon/icons/fastapi/fastapi-original.svg?raw";
import rails from "devicon/icons/rails/rails-plain.svg?raw";
import ruby from "devicon/icons/ruby/ruby-original.svg?raw";
import go from "devicon/icons/go/go-original.svg?raw";
import rust from "devicon/icons/rust/rust-original.svg?raw";
import shopify from "../assets/stack-logos/shopify.svg?raw";

// id → inlined SVG markup (only the ones imported above).
const LOGOS: Record<string, string> = {
  shopify, nextjs, react, vuejs, nuxtjs, svelte, angular, astro, nestjs,
  express, nodejs, laravel, php, python, django, flask, fastapi, rails, ruby,
  go, rust,
};

// id → human label (tooltip + a11y).
const LABELS: Record<string, string> = {
  shopify: "Shopify", nextjs: "Next.js", react: "React", vuejs: "Vue",
  nuxtjs: "Nuxt", svelte: "Svelte", angular: "Angular", astro: "Astro",
  nestjs: "NestJS", express: "Express", nodejs: "Node.js", laravel: "Laravel",
  php: "PHP", python: "Python", django: "Django", flask: "Flask",
  fastapi: "FastAPI", rails: "Rails", ruby: "Ruby", go: "Go", rust: "Rust",
};

/** The row of tech-stack logos for a project (e.g. `["vuejs", "laravel"]`).
 *  Renders nothing when `ids` is empty or all-unknown, so it's safe to always
 *  mount. Each logo sits on a light tile so dark marks (Next.js) stay visible
 *  on the warm-dark theme. `size` is the logo edge in px. */
export function StackIcons({ ids, size = 14 }: { ids?: string[]; size?: number }) {
  const known = (ids ?? []).filter((id) => LOGOS[id]);
  if (known.length === 0) return null;
  return (
    <span className="stack-icons">
      {known.map((id) => (
        <span
          key={id}
          className="stack-ico"
          role="img"
          aria-label={LABELS[id] ?? id}
          title={LABELS[id] ?? id}
          style={{ width: size, height: size }}
          dangerouslySetInnerHTML={{ __html: LOGOS[id] }}
        />
      ))}
    </span>
  );
}
