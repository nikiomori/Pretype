# Releasing

The repository has no signing secrets. Thus CI cannot make the build that users download. CI makes a draft release. The maintainer replaces the CI zip with a notarized zip from a local build. Then the maintainer publishes the release.

> **WARNING:** Do not publish the CI zip. It has an ad-hoc signature, so Gatekeeper blocks it. Its signature is also different from the Developer ID build. After users update to that zip, their Accessibility grant stops working, and macOS shows no message.

<div align="center">
<img src="diagram-release-flow.svg" width="340" alt="Release flow. In GitHub Actions: 1, push the tag vX.Y.Z; CI makes a draft release with an ad-hoc signed zip. On the maintainer's Mac: 2, build from the tag with make-app.sh, then sign, notarize and staple with dist.sh. On GitHub and Homebrew: 3, upload the zip with --clobber; 4, download and verify it with spctl and stapler; 5, publish the draft; 6, bump the Homebrew cask version and sha256." />
</div>

## Procedure

1. **Push the tag.**

   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

   The workflow `.github/workflows/release.yml` then lints, tests and builds with `Scripts/make-app.sh` + `Scripts/dist.sh` (ad-hoc). It creates a **draft** release with `Pretype.app.zip` and generated notes.

2. **Build locally from the tag.** You need the "Developer ID Application" certificate in the keychain. You also need the notary profile. Create the profile one time with `xcrun notarytool store-credentials pretype`.

   ```sh
   PRETYPE_VERSION=X.Y.Z ./Scripts/make-app.sh
   ./Scripts/dist.sh   # hardened-runtime sign, notarize (--keychain-profile pretype), staple
   ```

   > **NOTE:** `notarytool --wait` can stop after a short network failure. The submission continues on the server. Do not submit again. Check the status with `xcrun notarytool history --keychain-profile pretype`.

3. **Replace the CI zip.**

   ```sh
   gh release upload vX.Y.Z build/Pretype.app.zip --clobber
   ```

4. **Verify the zip that is attached to the release**, not the local copy.

   ```sh
   rm -rf /tmp/pt && gh release download vX.Y.Z -p Pretype.app.zip -D /tmp/pt
   ditto -x -k /tmp/pt/Pretype.app.zip /tmp/pt
   spctl -a -t exec -vv /tmp/pt/Pretype.app      # expect: source=Notarized Developer ID
   xcrun stapler validate /tmp/pt/Pretype.app    # expect: The validate action worked!
   ```

5. **Publish the draft.**

   ```sh
   gh release edit vX.Y.Z --draft=false
   ```

6. **Bump the Homebrew cask** in `nikiomori/homebrew-tap` (`Casks/pretype.rb`):
   1. Set `version` to `X.Y.Z`.
   2. Set `sha256` to the output of `shasum -a 256 build/Pretype.app.zip`.
   3. Commit with the message `pretype X.Y.Z`.

   > **NOTE:** Always bump the cask from the notarized zip, not from the CI zip.
