# The docs site

The workshop guide is a **GitHub Pages site** built from `docs/wiki/`:
<https://hybridcloudworks.github.io/Demo-IaC_Demo_with_VSCode/>

It replaced the GitHub wiki in October 2026. The wiki used to be published
from this folder by `publish-wiki.yml` and `scripts/Publish-Wiki.ps1`; both are
gone, and so is the `wiki-check.yml` linter. The site was built from the newest
copy of every page, including edits that had only reached the live wiki.

## How it is published

`.github/workflows/pages.yml` runs on every push to `main` that touches
`docs/wiki/**`. It builds the folder with Jekyll and the
[just-the-docs](https://just-the-docs.com/) theme (`docs/wiki/_config.yml`) and
deploys it to Pages. Edit pages on a branch and review them in a pull request
like any other file. Nothing builds the site on a pull request, so check the
**Docs site** run after merging.

## Rules for this folder

- Every page starts with front matter carrying its title (`title: ...`), and
  has exactly one H1.
- `index.md` is the home page. Its **On this site** list replaced the wiki
  sidebar, so link new pages from there.
- Link to another page by file name, `[L1.2](Curriculum-L1-2-Architecture-Expansion.md)`;
  the site turns that into a link to the `.html` page. Link to files elsewhere
  in the repo with absolute `https://github.com/HybridCloudWorks/Demo-IaC_Demo_with_VSCode/blob/main/…`
  URLs, and to images relatively (`src="bicep.png"`).
- Keep the folder flat so those relative image paths keep working.
- A page that shows `${{ ... }}` or `{% ... %}` must wrap its content in
  `{% raw %}` … `{% endraw %}`, or Jekyll's Liquid templating will mangle it.

## Icons

Two tiers, and the distinction is deliberate.

**Vendor logos** — `bicep.png`, `gh-actions.png`, `gh-copilot.png`. Used *only* in
the lab deploy chooser, because that is the one place the reader picks between
real products. Full colour, and never redrawn or recoloured.

**Supporting icons** — `icon-*.svg`, taken from
[Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons)
(Microsoft's own set, MIT licensed, so redistribution here is clean). They are
monochrome line icons, recoloured from Fluent's `#212121` to `#6e7781` so they
clear 4.5:1 contrast on both light and dark backgrounds. `icon-azure-rbac.svg`
and `icon-entra-id.svg` are placeholders still waiting to be swapped for real
icons.

**No OS brand marks.** The Windows flag and Apple logo are trademarks with their
own usage terms, not MIT — hence neutral Desktop/Laptop icons, with the label
doing the naming.
