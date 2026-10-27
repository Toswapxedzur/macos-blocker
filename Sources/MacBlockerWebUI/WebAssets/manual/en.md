# Mac Vault user manual

Mac Vault has three pages: **Vault** blocks native apps, **Classifier** tags supported browser content, and **Activity** shows recorded use. The browser extension collects supported content and applies browser blocking. Install and connect it in the browser you use.

## Quick start

1. In **Vault**, add a blocking group and an Apps target, then select apps with the + picker.
2. Choose the group's blocking behavior and enable it.
3. In **Classifier**, create a group, choose its platforms, and add tags with descriptions.
4. Open Settings → Connections and choose ChatGPT subscription, OpenAI API, Gemini API or Grok API. Connect the account or add a key and fetch its models, then select a connection/model in the group. Enable tagging and resume the group.
5. Open supported content in the connected browser. Configure a tag filter in a browser blocking group if you want the tags to control blocking.

## Blocking groups

A **blocking group** applies a blocking policy. A **Classifier group** assigns tags to content; it does not block anything by itself.

1. Add a blocking group and give it a name.
2. Choose targets under **Applies to**.
3. Choose when blocking applies, then set any schedule or time allowance.
4. Enable the group. Its targets share the group's policy.

Routine edits save automatically. An error means the edit was not accepted; correct the field and try again. Disable a group to stop its policy while keeping its configuration. **Delete group** removes it. Drag groups to reorder them. More than one group can apply to a target; snoozing one does not lift another group's block.

**Export** copies a group configuration. **Import** replaces the selected group's configuration after confirmation.

### Time allowance and schedule

**Block immediately** applies whenever the enabled group matches and its schedule is active. **Block when the time allowance is used** permits matching use until its allowance runs out.

Set the allowance in minutes and the reset interval in hours. A rolling limit counts use within the preceding window. Resetting at midnight starts a new period at local midnight, including for a rolling limit.

Choose active weekdays and optional local-time windows, one per line, such as **09:00-12:00**. An empty window list applies throughout the selected days. A window must end later than it starts on the same day; split an overnight schedule into separate days.

### Snooze

Configure snooze in each blocking group. **Pause blocking** suspends that group's policy for its pause duration. **Add to the time allowance** adds usable minutes to a time-limited group. Only consumed extra allowance counts as snoozed time. Unused extra allowance expires at the next reset; for a rolling limit it expires after one window, or sooner at midnight if enabled.

**Activation delay** postpones snooze while blocking continues. **Cooldown** is the wait after snooze ends before another request. **Required confirmations** sets the number of confirmation steps. Snooze is available on a frozen group only if allowed before freezing.

### Freeze and PIN

**Freeze** prevents routine edits. Unfreezing requires ten confirmations, five seconds apart, plus any configured wait and six-digit PIN. **Wait before unfreezing** accepts 0–72 hours; 0 adds no wait.

While frozen, the wait can be extended and a PIN can be added if none exists. Those conditions cannot be weakened until the group is unfrozen. Deletion also respects the remaining wait and PIN.

### Linked groups

Use **Link** to connect explicitly selected groups in other Vault programs. Linked groups share their name, supported policy settings, targets, usage, and freeze conditions. Each program edits and enforces the target types it supports; other target entries remain available to linked programs. Unlinking keeps each group and its settings.

If a linked member is offline, editing can be unavailable. Open Mac Vault and the linked browser to reconnect. A local saved policy can continue to apply while a member is offline.

## Getting help

Click the small **i** beside a field to see its explanation. Click outside it or press Escape to close it. Lists stay inside scrollable boxes; scroll the box to reach more entries. Search filters the visible list without deleting entries.

Custom rules have their own [Code manual](../code-manual/en.md). It explains the editor, activation, logs, file access, and the supported API.

## Native apps

Use an Apps target's + picker to select installed or currently running apps. Reopen the picker to refresh its list when you launch an app from another folder. **Block every app except these** turns the list into an allowlist. Mac Vault can block ordinary Apple apps and whole browsers; Mac Vault itself and any app sharing its bundle identifier remain protected.

A blocked app is asked to quit. **Ask a blocked app to quit again every (minutes)** controls retries. Website redirects, page pauses, and feed hiding are enforced by the browser extension; they do not become native app actions.

## Classifier

A Classifier group tags content from its assigned platforms with its own tag tree and model settings. Each platform belongs to one group. Choose platforms when creating the group; they cannot be changed afterward. Blocking-group schedules and filters do not control tagging.

Enable tagging in Settings. Use each group's **Pause tagging / Resume tagging** separately. Turning off a platform feed's recording in **Activity → Recording** also stops its tagging.

### Tags and model settings

Create tags, describe their meanings, and set or remove their parents in the tag tree. Drag a tag to move its branch. Clear descriptions help the model distinguish similar tags. Each group's settings are independent.

- **Strict ↔ Broad** sets confidence requirements and default tag counts.
- **Minimum tags / Maximum tags** in More replace those default counts. Strict ↔ Broad still controls confidence for additional tags. Leave either field empty to use its default.
- **Tagging instructions** adds optional instructions for this group.

Routine Classifier edits save automatically. Each group uses one explicitly selected connection, model and reasoning effort.

### Connections

Settings has four choices: **ChatGPT subscription**, **OpenAI API**, **Gemini API**, and **Grok API**. ChatGPT subscription uses Vault’s own sign-in and your eligible plan. API keys use the selected provider’s API billing and limits. Add the key in its connection, choose **Fetch model list**, and select the model in your classifier group. Fetching models does not choose one for you.

**Reasoning effort** controls how much the selected model thinks: Model default, Low, Medium or High where supported. Higher effort can add time and token usage. Web search is always enabled for tagging; the model decides when it needs to search. Choose a model that supports search and structured tagging. Failed or unavailable requests keep valid cached results; new items remain unresolved until you choose **Retry cloud classification**. Vault does not switch providers automatically.

Correct a content item's tags in the browser extension. Click **+ tag**, search the Classifier's existing tags, and choose one to add it. Use a tag's remove control, or select it and press Delete once, to remove it. **Untagged** means tagging finished with no tags; **Tagging** means a result is pending. Corrections inform future tagging.

## Activity

Activity records enabled app use, website visits, and supported **Content viewed** locally. Its charts reflect recorded data; a blank area does not prove the Mac was idle.

Choose a date range. **Timeline** shows use at its time of day; **Totals** sums duration. **Time interval** combines usage within each interval into vertical blocks. **Colors** is a clickable legend: select a source to focus the charts on it. Select a day to view use since that day.

### Activity groups

Create a group to show its selected apps and websites together in Usage. **Merge** uses one name and color for its members throughout Activity. An Activity group organizes recorded use; it is separate from a blocking group or Classifier group. Save the Activity group editor explicitly with **Save**.

### Recording and retention

In **Recording**, turn recording on or off for each category or individual source. **Keep** controls how long history is retained; **Forever** keeps it without an automatic expiry. Individual choices can follow the broader setting. Turning recording off stops new recording; deleting history removes recorded entries.

Platform feeds collect content shown on supported platform pages, whether opened or not. A feed with **Tagging supported** can supply the Classifier while recording is on. Its retention controls collected content separately from app and website usage. A paused Classifier group does not itself turn off recording.

## Settings

Choose the interface language in Settings. Field explanations are available through the small Info buttons in the selected interface language.

## Saving and troubleshooting

Routine Vault and Classifier edits save automatically. Activity group editing uses **Save**. Adding, deleting, connection tests and model-list fetching remain explicit actions.

If tags are missing, check the browser connection, global tagging switch, group pause state, platform recording, selected connection/model and its credentials. If research does not run, check consent, group choice, provider credentials, research model, and the research status. If a linked group cannot be edited, reconnect its programs or unfreeze it as indicated.
