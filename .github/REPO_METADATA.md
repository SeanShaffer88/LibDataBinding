# Repository metadata (GitHub settings)

Everything on this page is applied in the **repository settings UI**, not by the
code. It is kept in the repo so the values are reviewable, versioned and
copy-paste ready.

> The `PATCH /repos/{owner}/{repo}` and `PUT /repos/{owner}/{repo}/topics`
> endpoints require *Administration* permission on the token. Automation tokens
> that can push code and publish releases may not have it (`403 Resource not
> accessible by integration`).

---

## Description

```
Reactive data binding for WoW Classic Forever addons (Interface 11507). Bind FontStrings, StatusBars and Textures to unit stats, custom variables and events — one widget write per frame, no OnUpdate polling, no taint. Embeds via LibStub.
```

## Topics

```
world-of-warcraft  wow  wow-addon  wow-classic  addon  lua  library  libstub  data-binding  reactive  ui  api
```

`Settings → General → Topics`. Topics drive GitHub search and the "used by"
recommendations, so keep them lowercase and hyphenated.

## Icon / logo

| Where | File | Notes |
| --- | --- | --- |
| Social preview | `.github/assets/social-preview.png` | 1280×640. `Settings → General → Social preview → Upload image`. |
| Repo/owner avatar | `.github/assets/icon.png` | 512×512 PNG. Used for the org/user avatar if you want the library to have its own mark. |
| README banner | `.github/assets/banner.png` | 1280×300, already referenced by both READMEs. |
| In-game addon-list icon | `LibDataBinding-1.0/media/icon.png` | 64×64 RGBA, wired via `## IconTexture` in the TOC. Ships in releases. |

## Other settings worth setting

- **Website:** `https://github.com/SeanShaffer88/LibDataBinding/releases` (or a
  docs page once one exists).
- **Include in the home page:** enable *Releases*; consider disabling *Packages*
  and *Deployments* (unused).
- **Features:** Issues on (bug reports against a library are useful), Wiki off,
  Discussions optional, Projects off.
- **Branch protection on `main`:** require the `release` workflow's `test` job
  to pass before merging. Prevents a tagged release from ever pointing at a
  commit whose suite fails.

## Release checklist

1. Bump `## Version` in the TOC **and** `lib.VERSION` in the Lua file (the
   workflow fails the release if they differ from the tag).
2. Add a `CHANGELOG.md` section with the new version at the top.
3. Merge to `main`.
4. Tag the **merge commit** on `main` (there must be no code commits on
   `main` that the tag misses):

   ```bash
   git fetch origin
   git tag -a 1.0.3 -F .github/release-notes-1.0.3.md origin/main
   git push origin refs/tags/1.0.3
   ```

5. Publish the release for that tag. The `release` workflow runs the suite,
   verifies the version and icon paths, and attaches
   `LibDataBinding-1.0-<version>.zip`.

> Do not create a release with `gh release create <tag> --target main` before
> the tag exists on the newer commit: GitHub creates a lightweight tag at
> `main`'s current head, which can be an older commit than your work. Tag
> explicitly, then create the release from the tag.
