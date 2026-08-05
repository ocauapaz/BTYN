# Assets

| File | Use |
|---|---|
| `logo.svg` | The logo, as drawn. 148x170. |
| `icon.svg` | Square variant with margin, for 1:1 contexts. |

`editors/vscode/icon.png` is rasterised from `icon.svg` at 256x256 — the VS Code
marketplace requires a PNG and will not take an SVG.

Regenerate it after changing the logo:

```bash
npx @resvg/resvg-js-cli --fit-width 256 assets/icon.svg editors/vscode/icon.png
```

Kept as a one-off command rather than a build step: it runs when the logo
changes, which is close to never, and the alternative is a rasteriser
dependency in a repo that otherwise needs none.
