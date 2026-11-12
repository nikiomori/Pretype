# ChatGPT plan support

With a ChatGPT plan, you can use Pretype's text features without an API key. Pretype signs in directly with your system browser. It needs no command-line tool, no proxy service and no extra package. Your API keys and local models stay available.

## Use it

1. Open **Settings → API**.
2. Turn on **Use a hosted model for text**.
3. Select **ChatGPT subscription** as the provider.
4. Click **Continue with ChatGPT**. Sign in and give consent in the browser.
5. Select a model from the list of your account.
6. Click **Test connection**.

To sign in does not turn on text generation. The switch in step 2 does that.

| Feature | On the plan |
|---|---|
| Suggestions | Words completes your words on the Mac. To get sentence suggestions from ChatGPT, turn on **Suggestions on ChatGPT**. Each one takes about one second and uses your plan allowance. |
| Fix, reply, voice commands, dictation tidy-up | They use the plan. |
| Dictation | The plan does not transcribe speech. Dictation uses its own provider. |

You can save more than one account, also two accounts with the same email. You can change the account, reconnect, sign out, refresh the model list and test the connection. **Manage ChatGPT usage** opens ChatGPT Settings → Usage. There you control the plan allowance and the credits.

## Failures

| Failure | What Pretype does |
|---|---|
| Short network or server failure | It pauses for a short time, and then tries again. It keeps the account. |
| Expired or revoked session | It asks you to reconnect. |
| Missing plan permission, or an account that cannot use the plan | It tells you why the requests do not operate. |
| Plan allowance used up | It pauses the requests until you retry in **Settings → API**. The menu bar status tells you why. |

No failure changes the account, the provider or the billing. Pretype never changes to API-key billing.

## How it operates

* **Provider.** The `chatgpt` provider is for text only. It has no custom base URL and no API key. Stored settings need no migration.
* **Transport.** Requests go to the public Responses endpoint with `store: false`. Pretype keeps one idle WebSocket connection for each account session, for up to 15 seconds. Each request sends its own context and resets the conversation state. If the server refuses the WebSocket upgrade, Pretype uses HTTP with `stream: true`, inside the same deadline.
* **Complete answers only.** Pretype uses an answer only after `response.completed`. It never inserts part of an answer. It does not send a failed or quota-limited request again. One exception: if a reused idle connection fails before the first event, Pretype sends the request one time on a new connection.
* **Reasoning.** For short text tasks, Pretype asks for the fastest reasoning effort that the model list of the account gives (`none`, `minimal` or `low`). If the list gives none of these, Pretype sends no reasoning setting. Pretype never selects a paid service tier.
* **Sign-in.** OAuth with dynamic client registration, a persistent opaque host identifier, PKCE, state and nonce. The browser returns to a listener on `127.0.0.1` only. Pretype verifies the RS256 signature of the ID token against the OpenAI key set. It also verifies the identity, the client ID and the plan scope.
* **Credentials.** The tokens are in the login keychain item `app.pretype.chatgpt`. Settings contain no tokens. One renewal runs at a time, and Pretype saves the new tokens in one step. An account change cancels the requests in progress. A token renewal in progress continues and saves the new tokens to its own account. **Sign out** tries to revoke the session and removes the local tokens. If Pretype cannot confirm the revocation, it tells you.
* **Logs.** Prompts, tokens, authorization URLs and provider error bodies never go to the debug log.

See [Privacy → ChatGPT plan](privacy.md#chatgpt-plan-optional) for what goes to OpenAI.

## Test it

Automated tests cover hostile OAuth callbacks and ID tokens, refused scopes, account isolation, token rotation, keychain failures, the end states of a stream, quota failures, and stale or cancelled results.

Before a release that changes this code, do these steps:

1. Sign in, change the account, reconnect and sign out.
2. Do a fix, a reply and a suggestion in TextEdit and in Notes.
3. Measure the real latency of a fix. The connection test is too small to show it.

## Provider references

We checked these pages on 2026-11-05. These preview interfaces can change.

- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Accounts, refresh and revocation](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [WebSocket transport](https://developers.openai.com/api/docs/guides/websocket-mode)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)
