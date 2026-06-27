# Lingueez — KOReader plugin

**[lingueez.app](https://lingueez.app)** &nbsp;·&nbsp; [github.com/lysak-yurii/lingueez](https://github.com/lysak-yurii/lingueez)

Save words straight from your e-reader into your Lingueez vocabulary — translated,
tagged, and synced to the [desktop](https://github.com/lysak-yurii/lingueez) and [web app](https://lingueez.netlify.app) the moment you look them up.

While you read, long-press a word and tap **Save to Lingueez**: the plugin detects
the language, translates it, and stores it in your account. By the time you next open
Lingueez on your computer, in reader or in the web, the word is already there — ready to study.

## Features

- **Flashcards - Review on the reader** — flip through flashcards and your saved words right where
  you read.
- **Quick save while you read** — long-press any word and save it without leaving the book.
- **Instant translation** — Google Translate built in, with optional DeepL.
- **Knows the language** — the source language is detected from the book, so there is
  nothing to pick for each word.
- **One vocabulary, everywhere** — words sync to the same account as the [Lingueez](https://lingueez.app)
  desktop and [web app](https://lingueez.netlify.app), kept private to you.
- **Texts, not just words** — save the chapter you're reading to your
  Lingueez library to study later with
  side-by-side translation in the desktop and web app,
  and download your saved texts back onto your reader.

## Install

1. Copy the `lingueez.koplugin` folder into your KOReader plugins directory:
   - **Android** — `/sdcard/koreader/plugins/`
   - **Linux** — `~/.config/koreader/plugins/`
   - **Kobo / Kindle / other** — see the KOReader documentation for the plugin path.
2. Restart KOReader. The plugin appears in **Plugin Management** and adds a
   **Lingueez** entry to the menu.

## Sign in

There is nothing to configure — the plugin connects to Lingueez and you simply sign in
with your account.

1. Open **Menu → Lingueez → Configure**.
2. Tap **Sign in (email)** and enter your Lingueez email and password, **or** tap
   **Sign in with Google** for the phone-assisted flow below.
3. That's it — everything you save is private to your account and shows up in the
   desktop and web apps.

> New to Lingueez? Create your account on the [desktop or web app](https://lingueez.app)
> first — the plugin signs you in, it doesn't register new accounts.

### Sign in with Google — scan with your phone

Typing on an e-reader is painful, so Google sign-in happens on your phone:

1. Tap **Sign in with Google** — the reader shows a **QR code**.
2. **Scan it with your phone** and sign in with Google there, with a real keyboard.
3. Your phone shows *"Signed in — return to your e-reader"*, and the reader picks it up
   within a couple of seconds and signs in **automatically**.

No phone or camera handy? Tap **Enter code manually** in the QR dialog instead.

## Saving words

- **While reading** — long-press a word, tap **Save to Lingueez**, tweak the
  translation if you like, and save.
- **From the menu** — select a word, then **Menu → Lingueez → Save Selected
  Word**.

Either way the word lands in your dictionary, marked *New*, ready to study in all your Lingueez platforms.

## Translation provider

Google Translate works out of the box. To use **DeepL** instead, copy `.env.example`
to `.env` next to the plugin and add your `DEEPL_API_KEY`.

## Troubleshooting

- **Plugin not in the menu** — enable it in Plugin Management, restart KOReader, and
  check the files are in the correct `.koplugin` directory.
- **Can't sign in** — confirm your Lingueez email and password (create the account on
  the [desktop](https://github.com/lysak-yurii/lingueez) or [web app](https://lingueez.netlify.app) first), check your internet connection, and make sure the
  device clock is correct.
- **Word won't save** — it's usually a duplicate (the same word and translation already
  exist), or there's no connection.

## Support

Having trouble installing or syncing? See [TROUBLESHOOTING.md](TROUBLESHOOTING.md). You can also [open an issue](https://github.com/lysak-yurii/lingueez.koplugin/issues).

## License

© 2024 Yurii Lysak. Licensed under the **GNU Affero General Public License v3.0** — you
may use, study, share, and modify it, and any distributed version (including over a
network) must remain open under the same license. This matches the license of KOReader
itself. See the [LICENSE](LICENSE) file for the full text.
