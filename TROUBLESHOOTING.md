# Troubleshooting

Common issues and how to resolve them.

## The plugin doesn't appear in the menu

The plugin only loads while a book is open, so first **open any document**, then look
under **Menu → Tools → Lingueez**. If it's still missing, work through the checks below.

### 1. Confirm it's installed in the right place

The folder must be named exactly `lingueez.koplugin` and sit in your KOReader plugins
directory:

- **Android** — `/sdcard/koreader/plugins/lingueez.koplugin/`
- **Linux** — `~/.config/koreader/plugins/lingueez.koplugin/`
- **Kobo / Kindle / other** — see the KOReader documentation for the plugin path.

Inside that folder you should see at least `_meta.lua` and `main.lua`.

### 2. Enable the plugin

Go to **Settings → Plugin Management**, find **Lingueez**, and make sure it's switched
**on**.

### 3. Restart KOReader

Close KOReader completely, reopen it, and open a book. Plugins are only picked up on a
fresh start.

## "Save to Lingueez" doesn't show when I select a word

- Make sure you've actually selected text — long-press a word until it's highlighted.
- The **Save to Lingueez** button appears in the highlight popup and in the
  dictionary lookup popup.
- If it never appears, restart KOReader so the plugin can re-attach to word selection.

## I can't sign in

- Double-check your Lingueez email and password. Create your account on the
  [desktop or web app](https://lingueez.app) first — the plugin signs you in, it
  doesn't register new accounts.
- Confirm the reader is online.
- Make sure the device's **date and time are correct** — sign-in tokens are
  time-sensitive and will be rejected if the clock is off.

## A word won't save

- It's usually a duplicate — the same word and translation already exist in your
  dictionary.
- Otherwise, check that the reader is online and that you're signed in
  (**Menu → Lingueez → Configure**).

## Still stuck? Check the logs

KOReader writes a log that often explains the problem. Look for lines beginning with
`Lingueez:` — for example, a successful start logs *"Lingueez plugin initialized
successfully"*.

- **Linux** — `~/.config/koreader/crash.log`
- **Android** — the KOReader log file (or `logcat`)
- **Other platforms** — see the KOReader documentation for the log location.

When reporting an issue, include your KOReader version and any `Lingueez:` log lines
around the problem — it makes things much faster to diagnose.

## Still need a hand?

If none of the above resolves it, please
[open an issue](https://github.com/lysak-yurii/lingueez.koplugin/issues) — include your
KOReader version and any `Lingueez:` log lines from above so we can get to the bottom of
it quickly.

You can also reach us at **[support@lingueez.app](mailto:support@lingueez.app)** — we're
happy to help.
