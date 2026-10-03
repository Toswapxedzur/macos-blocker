(() => {
  "use strict";
  // Presentation only: known Vault notices have catalog templates. Backend
  // error strings, policy data, provider diagnostics and captured IDs stay
  // unchanged. Unknown external or OS errors are shown verbatim.
  const fields = {
  "the name": "notice.field.1",
  "tagging instructions": "notice.field.2",
  "Speed ↔ Quality": "notice.field.3",
  "Strict ↔ Broad": "notice.field.4",
  "research for this group": "notice.field.5",
  "minimum tags": "notice.field.6",
  "maximum tags": "notice.field.7",
  "tag counts (minimum must not exceed maximum)": "notice.field.8",
  "the Classifier group": "notice.field.9",
  "the tag tree": "notice.field.10",
  "the tag": "notice.field.11",
  "the parent tag": "notice.field.12",
  "the provider": "notice.field.13",
  "the platform": "notice.field.14",
  "platforms": "notice.field.15",
  "the research provider": "notice.field.16",
  "the research model": "notice.field.17",
  "the research provider and model": "notice.field.18",
  "a research provider with built-in web search": "notice.field.19",
  "the model": "notice.field.20",
  "the test model": "notice.field.21",
  "provider credentials": "notice.field.22",
  "the endpoint": "notice.field.23",
  "the description": "notice.field.24",
  "the subject": "notice.field.25",
  "the content source": "notice.field.26",
  "history retention": "notice.field.27",
  "the folder": "notice.field.28",
  "the backup owner code": "notice.field.29",
  "the tag position": "notice.field.30",
  "this action": "notice.field.31",
  "this setting": "notice.field.32"
};
  const templates = [
  {
    "translationKey": "notice.contracts.1",
    "template": "Missing required field: {field}."
  },
  {
    "translationKey": "notice.contracts.2",
    "template": "{field} exceeds its limit of {maximum}."
  },
  {
    "translationKey": "notice.contracts.3",
    "template": "Invalid value for {field}."
  },
  {
    "translationKey": "notice.groundedResearch.1",
    "template": "The research providers or sanitized subject are invalid."
  },
  {
    "translationKey": "notice.groundedResearch.2",
    "template": "The research provider returned no usable description."
  },
  {
    "translationKey": "notice.localModelBackup.1",
    "template": "Choose a local folder for Vault Classifier backups."
  },
  {
    "translationKey": "notice.localModelBackup.2",
    "template": "The backup folder must be a local directory other than the filesystem root."
  },
  {
    "translationKey": "notice.localModelBackup.3",
    "template": "The backup folder cannot be a symbolic link."
  },
  {
    "translationKey": "notice.localModelBackup.4",
    "template": "Enable local backup mode before creating a snapshot."
  },
  {
    "translationKey": "notice.localModelBackup.5",
    "template": "Use an owner code with at least eight characters."
  },
  {
    "translationKey": "notice.localModelBackup.6",
    "template": "The local backup owner code could not be stored securely on this device."
  },
  {
    "translationKey": "notice.localModelCatalog.1",
    "template": "The model repository is invalid."
  },
  {
    "translationKey": "notice.localModelCatalog.2",
    "template": "The model file name is invalid."
  },
  {
    "translationKey": "notice.localModelCatalog.3",
    "template": "The model download URL is invalid."
  },
  {
    "translationKey": "notice.localStore.1",
    "template": "Collection is not enabled for this platform."
  },
  {
    "translationKey": "notice.localStore.2",
    "template": "The platform did not provide a stable entry identifier."
  },
  {
    "translationKey": "notice.localStore.3",
    "template": "The platform did not provide a stable creator identifier."
  },
  {
    "translationKey": "notice.localStore.4",
    "template": "The platform entry does not contain a title."
  },
  {
    "translationKey": "notice.localStore.5",
    "template": "Advertisements are not collected."
  },
  {
    "translationKey": "notice.localStore.6",
    "template": "The Classifier group cannot correct this platform."
  },
  {
    "translationKey": "notice.localStore.7",
    "template": "The collected content is no longer available."
  },
  {
    "translationKey": "notice.localStore.8",
    "template": "The correction contains a tag that is not eligible for this Classifier group."
  },
  {
    "translationKey": "notice.packageLifecycle.1",
    "template": "This package manifest uses an unsupported schema."
  },
  {
    "translationKey": "notice.packageLifecycle.2",
    "template": "The package manifest has invalid {field} metadata."
  },
  {
    "translationKey": "notice.packageLifecycle.3",
    "template": "The package manifest checksum is malformed."
  },
  {
    "translationKey": "notice.packageLifecycle.4",
    "template": "The package payload size does not match its signed manifest."
  },
  {
    "translationKey": "notice.packageLifecycle.5",
    "template": "The package payload did not pass its SHA-256 integrity check."
  },
  {
    "translationKey": "notice.packageLifecycle.6",
    "template": "The package was signed by an unknown key."
  },
  {
    "translationKey": "notice.packageLifecycle.7",
    "template": "The package was signed by a revoked key."
  },
  {
    "translationKey": "notice.packageLifecycle.8",
    "template": "The package manifest signature is invalid."
  },
  {
    "translationKey": "notice.packageLifecycle.9",
    "template": "The package payload cannot be validated."
  },
  {
    "translationKey": "notice.packageLifecycle.10",
    "template": "The package payload does not match its signed metadata."
  },
  {
    "translationKey": "notice.packageLifecycle.11",
    "template": "The package does not advance the accepted release metadata."
  },
  {
    "translationKey": "notice.packageLifecycle.12",
    "template": "A verified package is already waiting for activation."
  },
  {
    "translationKey": "notice.packageLifecycle.13",
    "template": "There is no verified package waiting for activation."
  },
  {
    "translationKey": "notice.packageLifecycle.14",
    "template": "There is no verified package available for rollback."
  },
  {
    "translationKey": "notice.packageLifecycle.15",
    "template": "A locally recorded package is unavailable."
  },
  {
    "translationKey": "notice.packageLifecycle.16",
    "template": "A locally recorded package does not match its lifecycle metadata."
  },
  {
    "translationKey": "notice.providerProtocols.1",
    "template": "The provider returned HTTP {status}."
  },
  {
    "translationKey": "notice.providerProtocols.2",
    "template": "The provider protocol configuration is invalid."
  },
  {
    "translationKey": "notice.providerProtocols.3",
    "template": "The provider protocol requires {field}."
  },
  {
    "translationKey": "notice.providerProtocols.4",
    "template": "The provider endpoint must use HTTPS, except an explicit loopback endpoint."
  },
  {
    "translationKey": "notice.providerProtocols.5",
    "template": "The provider protocol requires an endpoint."
  },
  {
    "translationKey": "notice.providerProtocols.6",
    "template": "The provider protocol does not support that operation."
  },
  {
    "translationKey": "notice.providerRecords.1",
    "template": "The provider credential is malformed."
  },
  {
    "translationKey": "notice.providerRecords.2",
    "template": "Enter a valid API key or token."
  },
  {
    "translationKey": "notice.providerRecords.3",
    "template": "The provider profile configuration is invalid."
  },
  {
    "translationKey": "notice.seedPackage.1",
    "template": "Missing bundled resource {name}."
  },
  {
    "translationKey": "notice.seedPackage.2",
    "template": "The bundled package checksum is malformed."
  },
  {
    "translationKey": "notice.seedPackage.3",
    "template": "The bundled seed package did not pass its integrity check."
  },
  {
    "translationKey": "notice.taxonomy.1",
    "template": "Taxonomy contains duplicate id {id}."
  },
  {
    "translationKey": "notice.taxonomy.2",
    "template": "Tag {nodeID} refers to missing parent {parentID}."
  },
  {
    "translationKey": "notice.taxonomy.3",
    "template": "Taxonomy has a parent cycle at {id}."
  },
  {
    "translationKey": "notice.workspaceCatalog.1",
    "template": "Duplicate local asset identifier: {value}."
  },
  {
    "translationKey": "notice.workspaceCatalog.2",
    "template": "The platform binding references a missing tag tree: {value}."
  },
  {
    "translationKey": "notice.workspaceCatalog.3",
    "template": "The platform binding references a missing classification dataset: {value}."
  },
  {
    "translationKey": "notice.workspaceCatalog.4",
    "template": "The platform binding references a missing Classifier group: {value}."
  },
  {
    "translationKey": "notice.workspaceCatalog.5",
    "template": "The active Classifier group is not compatible with the platform tree and dataset: {value}."
  },
  {
    "translationKey": "notice.workspaceCatalog.6",
    "template": "The collection platform is not supported: {value}."
  },
  {
    "translationKey": "notice.workspaceCatalog.7",
    "template": "The collected platform entry is invalid: {value}."
  },
  {
    "translationKey": "notice.workspaceCatalog.8",
    "template": "The API provider profile is invalid: {value}."
  },
  {
    "translationKey": "notice.workspaceCatalog.9",
    "template": "The Classifier group has incompatible local assets: {value}."
  },
  {
    "translationKey": "notice.workspaceCatalog.10",
    "template": "That platform is already assigned to another Classifier group: {value}. A platform can belong to only one group."
  },
  {
    "translationKey": "notice.officialPlatformConnectionTestProtocol.1",
    "template": "This official platform API connection is not ready for a health check."
  },
  {
    "translationKey": "notice.providerModelCatalogProtocol.1",
    "template": "This connection cannot list models."
  },
  {
    "translationKey": "notice.providerModelCatalogProtocol.2",
    "template": "The provider connection cannot build a model-list request."
  },
  {
    "translationKey": "notice.providerModelCatalogProtocol.3",
    "template": "The provider returned an unreadable or oversized model list."
  },
  {
    "translationKey": "notice.providerModelCatalogProtocol.4",
    "template": "The provider returned no usable model identifiers."
  },
  {
    "translationKey": "notice.providerTestProtocol.1",
    "template": "This provider protocol does not support a safe test request yet."
  },
  {
    "translationKey": "notice.providerTestProtocol.2",
    "template": "Enter a test model for this provider connection."
  },
  {
    "translationKey": "notice.providerTestProtocol.3",
    "template": "Store a provider credential before testing this profile."
  },
  {
    "translationKey": "notice.providerTestProtocol.4",
    "template": "The provider test returned an invalid response."
  },
  {
    "translationKey": "notice.modelDownloadManager.1",
    "template": "That model is already downloading."
  },
  {
    "translationKey": "notice.modelDownloadManager.2",
    "template": "The model server returned HTTP {status}."
  },
  {
    "translationKey": "notice.modelDownloadManager.3",
    "template": "The local model folder is unavailable."
  },
  {
    "translationKey": "notice.modelDownloadManager.4",
    "template": "The downloaded model file is unavailable."
  },
  {
    "translationKey": "notice.localHubAuthentication.1",
    "template": "Could not create local hub authentication material."
  },
  {
    "translationKey": "notice.localHubAuthentication.2",
    "template": "The local hub authentication request is invalid."
  },
  {
    "translationKey": "notice.localHubAuthentication.3",
    "template": "Could not store local hub authentication material on this Mac."
  },
  {
    "translationKey": "notice.localHubAuthentication.4",
    "template": "Local hub authentication material already exists."
  },
  {
    "translationKey": "notice.localHubAuthentication.5",
    "template": "Development and production local-hub authentication material conflict."
  },
  {
    "translationKey": "notice.localHubAuthentication.6",
    "template": "Could not move local-hub authentication material into development."
  },
  {
    "translationKey": "notice.sharedBrowserBridgeMessages.1",
    "template": "The collection diagnostic platform is invalid."
  },
  {
    "translationKey": "notice.sharedBrowserBridgeMessages.2",
    "template": "The video-tag platform is invalid."
  },
  {
    "translationKey": "notice.sharedBrowserBridgeMessages.3",
    "template": "The video-tag evidence is invalid."
  },
  {
    "translationKey": "notice.sharedBrowserBridgeMessages.4",
    "template": "The bridge payload is invalid."
  },
  {
    "translationKey": "notice.inputPositiveInteger",
    "template": "{field} must be a positive whole number."
  },
  {
    "translationKey": "notice.inputNonnegativeInteger",
    "template": "{field} must be a whole number of 0 or more."
  },
  {
    "translationKey": "notice.inputPositiveNumber",
    "template": "{field} must be a positive number."
  },
  {
    "translationKey": "notice.backupLocked",
    "template": "Enter the local backup owner code before changing backup mode."
  },
  {
    "translationKey": "notice.inputCheck",
    "template": "Check {field} and try again."
  },
  {
    "translationKey": "notice.inputLimit",
    "template": "Use at most {limit} characters for {field}."
  },
  {
    "translationKey": "notice.inputChoice",
    "template": "Choose a supported value for {field}."
  },
  {
    "translationKey": "notice.fixedPlatforms",
    "template": "Platforms cannot be changed after the group is created."
  },
  {
    "translationKey": "notice.noPlatforms",
    "template": "Select at least one platform."
  },
  {
    "translationKey": "notice.backupCodeMismatch",
    "template": "The local backup owner code did not match."
  },
  {
    "translationKey": "notice.modelMissing",
    "template": "The selected model is not in the local catalog."
  },
  {
    "translationKey": "notice.termLookupUnavailable",
    "template": "Could not look that term up: research is off or not configured, the term is too short or too generic, or it is already queued. You can write the description yourself instead."
  },
  {
    "translationKey": "notice.creatorNotRecognized",
    "template": "That creator was not recognised. Paste a link to their page, their @handle (r/name on Reddit), or the exact name of a creator already seen here."
  },
  {
    "translationKey": "notice.creatorLookupUnavailable",
    "template": "Could not look this creator up: research is off for this platform, or it is already queued. You can write the description yourself instead."
  },
  {
    "translationKey": "notice.backupUnlocked",
    "template": "Backup controls are unlocked for this app session."
  },
  {
    "translationKey": "notice.backupEnabled",
    "template": "Private local snapshots are enabled. Use Create backup now when you want a new snapshot."
  },
  {
    "translationKey": "notice.backupDisabled",
    "template": "Local backups are off. Existing snapshots were left untouched."
  },
  {
    "translationKey": "notice.backupCreated",
    "template": "Local model snapshot created in {folder}."
  },
  {
    "translationKey": "notice.termLookupPending",
    "template": "Looking up “{subject}”. It appears under Known terms when the lookup finishes."
  },
  {
    "translationKey": "notice.creatorLookupPending",
    "template": "Looking up this creator. It appears under Known creators when the lookup finishes."
  },
  {
    "translationKey": "notice.dictionaryFormat",
    "template": "The dictionary format or checksum is invalid."
  },
  {
    "translationKey": "notice.dictionaryUnavailable",
    "template": "The dictionary server is unavailable. Your local knowledge remains usable."
  },
  {
    "translationKey": "notice.dictionaryPersonalFormat",
    "template": "Use a schemaVersion 1 personal dictionary with valid entries."
  },
  {
    "translationKey": "notice.dictionaryTooLarge",
    "template": "This dictionary file exceeds the supported size."
  },
  {
    "translationKey": "notice.dictionaryUpdated",
    "template": "Dictionary updated. Personal definitions are preserved."
  }
];
  const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const rules = templates.map(rule => {
    const names = [];
    const parts = rule.template.split(/(\{[A-Za-z0-9_]+\})/g);
    const pattern = parts.map(part => {
      if (/^\{[A-Za-z0-9_]+\}$/.test(part)) { names.push(part.slice(1, -1)); return "([\\s\\S]+?)"; }
      return escape(part);
    }).join("");
    return { ...rule, names, pattern: new RegExp("^" + pattern + "$") };
  });
  rules.sort((a, b) => a.names.length - b.names.length);
  window.VaultNoticeLanguage = (value, translate) => {
    const text = String(value ?? "");
    for (const rule of rules) {
      const match = text.match(rule.pattern);
      if (!match) continue;
      const values = Object.fromEntries(rule.names.map((name, index) => {
        const raw = match[index + 1];
        const fieldKey = name === "field" ? fields[raw] : null;
        const localized = fieldKey ? translate(fieldKey) : raw;
        return [name, fieldKey && localized === fieldKey ? raw : localized];
      }));
      const result = translate(rule.translationKey, values);
      return result === rule.translationKey ? text : result;
    }
    return text;
  };
})();
