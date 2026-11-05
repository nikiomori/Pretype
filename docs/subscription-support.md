# ChatGPT plan usage in Pretype

## Problem and scope

People who already subscribe to ChatGPT should be able to use their plan for Pretype's text features without creating an API key. Add direct browser sign-in, with no CLI, proxy service, or new package dependency. Existing API keys and local models remain available. The feature is opt-in and uses the same text/context boundaries and output gates as the hosted text engine.

The first contribution covers suggestions, fixes, replies, rewrites, and dictation cleanup. Transcription keeps its independent configuration: ChatGPT plan usage does not support the transcription endpoint. Claude remains an API-key provider. Direct Claude subscription authentication is deferred: Anthropic restricts third-party apps from handling subscription credentials; the supported unmodified Claude Code route would introduce a CLI dependency outside this scope.

## Experience

Choose **ChatGPT subscription** under Settings → API → Text, then **Continue with ChatGPT**. The system browser handles authentication and consent. Signing in does not enable text generation. Choose a model from the signed-in account's catalog and explicitly enable the text provider. Show saved registrations separately, including registrations with identical emails. Allow switching, reconnecting, signing out, refreshing models, and testing the connection. Link to ChatGPT Settings → Usage, where the user controls plan allowance and credits.

An expired or revoked session asks for reconnection. Missing plan permission or ineligibility explains why inference is unavailable. Usage exhaustion pauses requests until the user explicitly retries. No failure switches accounts, providers, or billing paths automatically. Existing local and API-key choices are retained by their current settings semantics.

## Design

- A distinct `chatgpt` provider reuses the persisted text-provider selection without changing old configuration decoding. It is not an audio provider and cannot use a custom base URL or API key.
- A shared text transport feeds the existing CloudEngine prompt construction and gates. The new transport uses the public Responses endpoint with `store: false`, `stream: true`, and only supported fields. Results are usable only after `response.completed`; partial or stale output is discarded.
- Native OAuth uses dynamic registration, a persistent opaque host UUID, PKCE, state, nonce, an IPv4 loopback callback, and RS256 ID-token verification against OpenAI's JWKS. Validate identity, issued client ID, and returned plan scope before enabling inference.
- Keep account registrations separate. Tokens live in a dedicated Keychain item; defaults contain no tokens. Refresh is serialized, rotating tokens are saved atomically, and account changes invalidate in-flight work. Logout attempts revocation and clears local tokens, reporting when remote revocation could not be confirmed.
- No prompts, tokens, authorization URLs, or provider error bodies enter diagnostics. Keep existing cloud-engine deadlines, bounded network recovery, and cancellation when typing or focus changes. Retain the account on transient failures.

## Acceptance and validation

Automated tests cover hostile OAuth callbacks and ID tokens, declined scopes, account isolation, token rotation, credential-storage failure, SSE terminal states, quota failures, and stale/cancelled results. Regression coverage includes existing API transports, configuration compatibility, all text actions, and privacy gates.

Run Swift build/tests with `--build-system swiftbuild`, SwiftLint, string synchronization/checks, and app packaging. Manually sign in, switch accounts, reconnect, sign out, and exercise TextEdit/Notes. A maintainer must run the private quality harness and report before/after coverage, first-word accuracy, saved characters, and p50 latency. Inference latency and actual account eligibility must be measured, not inferred from OAuth success.

Keep the contribution draft until independent review, CI, localization, live-account validation, and maintainer evaluation are complete. This contribution does not merge or release the app.

## Provider references

Verified November 5, 2026; these preview interfaces can change:

- [OpenAI registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Accounts, refresh, and revocation](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)
- [Anthropic authentication restrictions](https://code.claude.com/docs/en/legal-and-compliance)
