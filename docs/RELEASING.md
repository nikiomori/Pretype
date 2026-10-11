# Releasing

The repo has no signing secrets, so CI cannot produce the build users download. CI drafts the
release; the maintainer replaces its zip with a locally notarized one, then publishes.

**Never publish the CI zip.** It is ad-hoc signed: Gatekeeper blocks it, and because its
signature differs from the Developer ID build, every user's Accessibility grant silently
stops applying after they update.

1. **Tag.** `git tag vX.Y.Z && git push origin vX.Y.Z`. `.github/workflows/release.yml` lints,
   tests, builds with `Scripts/make-app.sh` + `Scripts/dist.sh` (ad-hoc) and creates a
   **draft** release with `Pretype.app.zip` and generated notes.
2. **Build locally from the tag** (needs the "Developer ID Application" certificate in the
   keychain and the notary profile, created once with `xcrun notarytool store-credentials pretype`):
   ```sh
   PRETYPE_VERSION=X.Y.Z ./Scripts/make-app.sh
   ./Scripts/dist.sh   # hardened-runtime sign, notarize (--keychain-profile pretype), staple
   ```
   `notarytool --wait` can die on a network blip; the submission continues, so check it with
   `xcrun notarytool history --keychain-profile pretype` rather than resubmitting.
3. **Replace the CI zip:** `gh release upload vX.Y.Z build/Pretype.app.zip --clobber`
4. **Verify what is actually attached**, not the local copy:
   ```sh
   rm -rf /tmp/pt && gh release download vX.Y.Z -p Pretype.app.zip -D /tmp/pt
   ditto -x -k /tmp/pt/Pretype.app.zip /tmp/pt
   spctl -a -t exec -vv /tmp/pt/Pretype.app      # expect: source=Notarized Developer ID
   xcrun stapler validate /tmp/pt/Pretype.app    # expect: The validate action worked!
   ```
5. **Publish** the draft (`gh release edit vX.Y.Z --draft=false`).
6. **Bump the Homebrew cask** in `nikiomori/homebrew-tap` (`Casks/pretype.rb`): set `version`
   to `X.Y.Z` and `sha256` to `shasum -a 256 build/Pretype.app.zip`, commit as `pretype X.Y.Z`.
   release.yml's tap step is skipped (no `TAP_GITHUB_TOKEN`); if that secret is ever added it
   would write the CI zip's hash, so the cask must still be bumped from the notarized zip.
