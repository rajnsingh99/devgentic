// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  site.config.js
//  devgentic-site
//
//  The ONE place that changes when a release is published. Everything else on the page is copy.
//
//  ⚠️ `release.published` IS THE DOWNLOAD SWITCH. While it is false the page shows "View on GitHub"
//  and "Build from source" and hides every download, checksum and version element, so nobody is
//  handed a dead link. Flip it only after `scripts/release.sh` has produced a notarized DMG AND the
//  GitHub Release exists with `Devgentic.dmg` attached.
//
//  ⚠️ FACTS BELOW MIRROR THE APP REPO'S README (requirements) AND scripts/release.sh (the single,
//  fixed asset name `Devgentic.dmg`). Do not invent numbers here — no sizes, no checksums, no
//  benchmarks — until they come from a real build.
//

export const SITE_CONFIG = {
  name: "Devgentic",

  release: {
    published: true,
    version: "1.0.1",         // e.g. "0.9.0" — shown as a badge once published
    sha256: "6237ddc9b4b9bcb9e44660d832812d29c8237638f60573c9b4c3118473cd650e", // printed by scripts/release.sh; shown beside the download once set
  },

  links: {
    repo: "https://github.com/rajnsingh99/devgentic",
    releases: "https://github.com/rajnsingh99/devgentic/releases",
    latestDmg: "https://github.com/rajnsingh99/devgentic/releases/latest/download/Devgentic.dmg",
    cloneUrl: "https://github.com/rajnsingh99/devgentic.git",
    issues: "https://github.com/rajnsingh99/devgentic/issues/new/choose",
    sponsor: "https://github.com/sponsors/rajnsingh99",
    author: "https://github.com/rajnsingh99",
    linkedin: "https://www.linkedin.com/in/rajnsingh99",
  },
};
