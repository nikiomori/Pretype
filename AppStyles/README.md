# App styles

How Pretype should write in a particular app or website: one short plain-text file per app. Every Pretype user who has that app installed can add your style in one click, with **Settings → Personalization → Per-app style → Fill In Suggested**. A style shapes reply drafts (<kbd>⌥⇧Tab</kbd>) everywhere, and completions in Instruct style.

## Share yours

The easy way is from the app. Write the style for your app under **Settings → Personalization → Per-app style**, use it for a while, then click the share button (↑) next to it. GitHub opens with the file filled in. Click **Propose new file** and then **Create pull request**; GitHub makes the fork for you.

By hand: add a file and open a pull request.

| What | Where |
|---|---|
| A Mac app | `apps/<bundle id>.txt`, e.g. `apps/com.tinyspeck.slackmacgap.txt` |
| A website | `sites/<host>.txt`, e.g. `sites/mail.google.com.txt` (no `www.`) |

To get an app's bundle ID, run `osascript -e 'id of app "Slack"'`, or add the app in Pretype's per-app list and hover its name. Write the file name in lowercase.

A site file covers that host's subdomains too: `sites/google.com.txt` would apply on mail.google.com. On a site, its style replaces the browser's.

## The file

```
# Slack
This is work chat: short, direct messages in a friendly professional tone.
Contractions are fine. Skip greetings and sign-offs. Emoji only when it adds meaning.
```

Lines that start with `#` are comments: put the app's name there, plus anything a reviewer should know. Everything else is the style.

**What makes a good style:**
- **English**, even for apps you write in another language. It steers tone, not language, and the models follow English instructions best.
- **About the kind of writing done in the app**, not about you: register, length, greetings, emoji, formatting habits. "Commit messages: imperative mood, under 72 characters" works; "I'm a backend developer at Acme" doesn't belong here.
- **Short:** under 400 characters, because the style rides along in every prompt.
- **Nothing personal:** no names, employers, addresses or signatures.

Pull request checks fail on a misnamed file, an empty style or one over the limit.
