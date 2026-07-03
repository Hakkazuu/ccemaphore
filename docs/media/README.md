# Media assets

Public assets referenced by the README files (this folder is tracked — unlike `docs/internal/`).

## `demo.gif` — header demo

A short (~13 s) autoplaying, looping demo shown in the header of every `README*.md`. Drop the file
here as `demo.gif` and it appears automatically (all five READMEs reference `docs/media/demo.gif`).

Produce it from a screen recording (`⌘⇧5`) with an optimized palette so it stays small:

```sh
ffmpeg -i demo.mov -vf "fps=15,scale=900:-1:flags=lanczos,palettegen" palette.png
ffmpeg -i demo.mov -i palette.png \
  -lavfi "fps=15,scale=900:-1:flags=lanczos[x];[x][1:v]paletteuse" demo.gif
gifsicle -O3 --lossy=60 demo.gif -o demo.gif   # optional shrink; brew install gifsicle
```

Keep it lean (aim ≤ ~8 MB): the main levers are `fps` (12–15) and `scale` (700–900 px wide).

To switch to a click-to-play MP4 instead, don't commit a video here — upload the `.mp4` via a GitHub
issue/release attachment and replace the `<img>` block in the READMEs with the resulting
`https://github.com/…/assets/…` URL.
