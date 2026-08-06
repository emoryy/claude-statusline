# claude-statusline

A status line for [Claude Code](https://claude.com/claude-code) showing the account
in use, the model, context fill, and both usage quotas with their reset countdowns.
Layout collapses in three steps as the terminal narrows.

```
【you@example.com·Acme Inc】 Opus 5  ctx ████▏      42% (57k/200k)  sess █▍         14% ↻2h24m  week ▍          4% ↻6d4h
【you@example.com·Acme Inc】 O5  c ██    42%  s ▋     14% ↻2h24m  w ▏     4% ↻6d4h
【you@example.com·Acme Inc】 O5 c:42% s:14% ↻2h24m w:4% ↻6d4h
```

Percentages are colored green below 50%, yellow from 50%, red from 80%. Bars use
partial-block glyphs for eighth-of-a-cell resolution, so a 10-cell bar has 80
distinct levels.

## Install

```bash
git clone https://github.com/emoryy/claude-statusline ~/src/claude-statusline
chmod +x ~/src/claude-statusline/statusline.sh
```

Then in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /home/you/src/claude-statusline/statusline.sh"
  }
}
```

### Requirements

| Dependency | Used for |
|---|---|
| bash 4+ | arrays, `${var^^}` |
| `jq` | parsing the status line JSON, the account file and the API response |
| `curl` | fetching usage |
| GNU coreutils `date` | `date -d <iso8601>` for reset countdowns |
| `awk` | compact token formatting |
| `stty` (or tmux, or `tput`) | detecting the real terminal width |

macOS ships BSD `date`, which has no `-d`. Install `coreutils` and put `gdate`
ahead of it on `PATH`, or the reset countdowns are simply omitted (nothing else
breaks).

Your terminal font needs U+2588 to U+258F (block elements) and the fullwidth
brackets 【】. Without them the bar and the account tag misalign. Any font with
decent Unicode coverage (most Nerd Fonts, DejaVu Sans Mono, Iosevka) is fine.

## Usage quotas, and what they cost you

The `sess` (5 hour) and `week` (7 day) figures come from
`https://api.anthropic.com/api/oauth/usage`, the endpoint behind the `/usage`
command. To call it the script reads your OAuth access token out of
`$CLAUDE_CONFIG_DIR/.credentials.json` and sends it to that host as a bearer
token. The token is never printed, logged or written anywhere.

Read that paragraph before installing. If you would rather not have a shell
script touch your credentials, delete the "Fetch usage from API" block. The
account tag, model and context meter all work without it, and the two quota
slots render a dim `n/a`.

The endpoint is undocumented and can change or disappear without notice. Every
failure path degrades to `n/a` or to the last known figures rather than showing
a misleading 0%. `n/a` also appears when authenticating with an API key instead
of a subscription, or when credentials live in an OS keychain rather than in
`.credentials.json`.

Responses are cached for 5 minutes in `$CLAUDE_CONFIG_DIR/usage-cache.json`, so
the status line does not issue a request per render.

## Configuration

All optional; the defaults need no setup.

| Variable | Effect |
|---|---|
| `STATUSLINE_LABEL` | Replaces the account label. Default: the OAuth email, or the config directory's name when there is no OAuth account. |
| `STATUSLINE_ORG` | Forces the org segment text. `-` suppresses it. Default: the organization name for team and enterprise orgs, nothing otherwise. |
| `STATUSLINE_ORG_FALLBACK` | Org segment text used only when *no* team or enterprise org is active, e.g. `personal`. Rendered dim. Lets a config dir you expect to be on a team org flag when it isn't. |
| `STATUSLINE_ACCOUNT_COLORS` | Pins label colors per account: `"a@b.com=152,c@d.com=#c8b28a"`. Default: a color hashed from the label. |
| `STATUSLINE_ORG_COLOR` | Color of the org segment. Default: a warm brick `38;2;224;108;90`. |
| `STATUSLINE_CACHE_FILE` | Where to keep the usage cache. |
| `STATUSLINE_CACHE_TTL` | Cache lifetime in seconds. Default 300. |
| `STATUSLINE_COLS` | Forces a terminal width. Useful for testing the collapsed layouts. |

Colors accept an xterm-256 index (`152`), a hex triplet (`#98c0c0`), or a raw SGR
parameter string (`38;5;152`).

Set these in the `statusLine.command` itself, since the status line does not
inherit your interactive shell's environment:

```json
"command": "STATUSLINE_ORG=personal bash /home/you/src/claude-statusline/statusline.sh"
```

### Running two accounts side by side

With `CLAUDE_CONFIG_DIR` pointing at separate directories per account, each gets
its own label and a different hashed color, so a glance at the tag tells you
which account is spending. Pin the colors if you want them stable:

```json
"command": "STATUSLINE_ACCOUNT_COLORS=you@work.com=152,you@gmail.com=187 bash /home/you/src/claude-statusline/statusline.sh"
```

## Layout tiers

| Width | Layout |
|---|---|
| ≥ 100 | full, plus `(used/total)` token counts on the context meter |
| ≥ 90 | full labels, 10-cell bars |
| 70-89 | initials for labels, 5-cell bars, model abbreviated to `O5` / `H4.5` |
| < 70 | labels and percentages only, no bars |

A `[1m]` long-context marker in the model name becomes a trailing `+` (`S5+`).

## Notes

The bracket color tracks the `/color` session setting. That setting is not
exposed to status line scripts, so it is recovered by grepping the transcript for
the line Claude Code writes when it changes (`Session color set to: <name>`).
If that internal string ever changes the brackets fall back to gray. The grep
reads the whole transcript on every render; at 21 MB that measured 7 ms.

## License

MIT. See [LICENSE](LICENSE).
