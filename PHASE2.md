# Phase 2 — shared local Vault bridge

Vault Classifier, Mac Vault, and the Vault extension share one authenticated
localhost WebSocket hub at `ws://127.0.0.1:8787`. Mac Vault is the only server
and owns that port; Vault Classifier and the extension are paired clients.
There is no Native Messaging host, second loopback server, or browser-host
registration step.

## Local path

1. The YouTube content adapter reads only values visibly rendered on a feed
   card or a fully opened watch page. It does not use the YouTube Data API.
   Classification stays separate from collection. Before collection, the
   adapter asks the local app for a tiny enabled-platform inventory; it sends
   no rendered title or creator metadata when YouTube collection is off.
   When the user turns collection on, it retains non-ad video/Short/live and
   Community-post entries by creator, including visible title, creator
   name/identifier, duration, view/publish/subscriber text where YouTube
   renders it, and the canonical entry URL. Ads are never retained.
2. The extension is inert until its local `vaultClassifierSettings.enabled`
   setting is `true`. When active, it sends a bounded entry payload through its
   existing shared Vault connection. A missing connection, missing classifier
   peer, malformed response, or timeout leaves the card/page visible.
3. In Vault Classifier's **Browser bridge** workspace, select **Connect to Mac
   Vault** and enter the same 64-character pairing key shown in Mac Vault. The
   key is held only in this Mac's Keychain; it never enters the WebView,
   classifier state file, diagnostic output, browser request, or response.
4. Mac Vault accepts one paired `classifier` peer and routes only bounded
   `bridge-info`, `collection-info`, `collect`, `classify`, and `correct`
   requests from browser peers to that peer. It owns request correlation,
   response destinations, a 32-request global route cap, and a six-second
   route expiry. Classifier replies cannot choose another browser connection.
5. The classifier returns only named policy identifiers/names, decisions, and
   correction acknowledgements. It never shares its tree, model, raw evidence,
   ledger, pairing key, or provider credentials.
6. Feed decisions default to **dim**, with Reveal and Why controls. Hard feed
   blocking requires the explicit `feedHardBlock` setting. A matching watch
   page presents a local block surface; revealing reports a local correction to
   the decision ledger.

## Setup

1. Open Mac Vault and turn on its existing web-app bridge server.
2. Connect the Vault extension to Mac Vault with the pairing key.
3. Open Vault Classifier, choose **Browser bridge**, and connect it with that
   same pairing key.
4. Reload the extension, then enable **Vault Classifier bridge** in Settings
   and choose an available named policy.

If any peer is disconnected or a routed request is invalid, unavailable, or
late, the extension fails open and leaves YouTube visible.

## Developer checks

```sh
cd /Users/fengyue.john.zhu/Desktop/blockerGroup/vaultClassifier
swift test
swift build

cd /Users/fengyue.john.zhu/Desktop/blockerGroup/macosBlocker
swift test

cd /Users/fengyue.john.zhu/Desktop/blockerGroup/customBlocker
./tests/run.sh
```
