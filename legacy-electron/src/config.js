const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const CONFIG_DIR_NAME = '.jikeyi-trans';
const LEGACY_CONFIG_DIR_NAME = '.mini-bob';
const STATE_FILE_NAME = '.jikeyi-trans.json';
const LEGACY_STATE_FILE_NAME = '.mini-bob.json';

const DEFAULT_SERVICE_ID = 'svc_default';
const DEFAULT_SERVICE_NAME = '默认服务';

const DEFAULT_SETTINGS = {
  env: {
    ANTHROPIC_BASE_URL: 'https://api.minimaxi.com/anthropic',
    ANTHROPIC_AUTH_TOKEN: 'REPLACE_WITH_YOUR_API_KEY',
    API_TIMEOUT_MS: '60000',
    ANTHROPIC_MODEL: 'MiniMax-M2.5',
    TARGET_LANGUAGE: '简体中文',
    TRANSLATE_SHORTCUT: 'CommandOrControl+Shift+T',
    OPEN_SETTINGS_SHORTCUT: 'CommandOrControl+Shift+O',
    POPUP_MODE: 'panel',
    TRANSLATOR_FONT_SIZE: '16'
  },
  routing: {
    autoRouteEnabled: true,
    fallbackEnabled: true
  },
  bubbleVisibleServiceIds: [],
  glossary: [],
  automation: {
    replaceLineBreaksWithSpace: false,
    stripCodeCommentMarkers: false,
    removeHyphenSpace: false,
    autoCopyOcrResult: false,
    autoCopyFirstResult: false,
    copyHighlightedWordOnClick: false,
    autoPlaySourceText: false
  }
};

function mergeEnvWithDefaults(env = {}) {
  return {
    ...DEFAULT_SETTINGS.env,
    ...env
  };
}

function normalizeBoolean(value, fallback) {
  if (typeof value === 'boolean') {
    return value;
  }
  return fallback;
}

function parseBooleanEnv(value, fallback) {
  if (value === undefined || value === null) {
    return fallback;
  }

  const normalized = String(value).trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) {
    return true;
  }
  if (['0', 'false', 'no', 'off'].includes(normalized)) {
    return false;
  }
  return fallback;
}

function normalizeRouting(rawRouting = {}) {
  return {
    autoRouteEnabled: normalizeBoolean(
      rawRouting?.autoRouteEnabled,
      DEFAULT_SETTINGS.routing.autoRouteEnabled
    ),
    fallbackEnabled: normalizeBoolean(
      rawRouting?.fallbackEnabled,
      DEFAULT_SETTINGS.routing.fallbackEnabled
    )
  };
}

function normalizeGlossary(rawGlossary = []) {
  if (!Array.isArray(rawGlossary)) {
    return [];
  }

  const dedupe = new Set();
  const result = [];

  for (const item of rawGlossary) {
    const source = String(item?.source || '').trim();
    const target = String(item?.target || '').trim();
    if (!source || !target) {
      continue;
    }

    const key = `${source}\u0001${target}`;
    if (dedupe.has(key)) {
      continue;
    }
    dedupe.add(key);
    result.push({
      source,
      target
    });
  }

  return result;
}

function normalizeAutomation(rawAutomation = {}) {
  const source = rawAutomation && typeof rawAutomation === 'object' ? rawAutomation : {};
  return {
    replaceLineBreaksWithSpace: normalizeBoolean(
      source.replaceLineBreaksWithSpace,
      DEFAULT_SETTINGS.automation.replaceLineBreaksWithSpace
    ),
    stripCodeCommentMarkers: normalizeBoolean(
      source.stripCodeCommentMarkers,
      DEFAULT_SETTINGS.automation.stripCodeCommentMarkers
    ),
    removeHyphenSpace: normalizeBoolean(
      source.removeHyphenSpace,
      DEFAULT_SETTINGS.automation.removeHyphenSpace
    ),
    autoCopyOcrResult: normalizeBoolean(
      source.autoCopyOcrResult,
      DEFAULT_SETTINGS.automation.autoCopyOcrResult
    ),
    autoCopyFirstResult: normalizeBoolean(
      source.autoCopyFirstResult,
      DEFAULT_SETTINGS.automation.autoCopyFirstResult
    ),
    copyHighlightedWordOnClick: normalizeBoolean(
      source.copyHighlightedWordOnClick,
      DEFAULT_SETTINGS.automation.copyHighlightedWordOnClick
    ),
    autoPlaySourceText: normalizeBoolean(
      source.autoPlaySourceText,
      DEFAULT_SETTINGS.automation.autoPlaySourceText
    )
  };
}

function normalizeServiceIdList(rawIds, services = []) {
  const validIds = new Set(
    (Array.isArray(services) ? services : [])
      .map((service) => String(service?.id || '').trim())
      .filter(Boolean)
  );
  const dedupe = new Set();
  const result = [];

  if (Array.isArray(rawIds)) {
    for (const item of rawIds) {
      const id = String(item || '').trim();
      if (!id || dedupe.has(id) || !validIds.has(id)) {
        continue;
      }
      dedupe.add(id);
      result.push(id);
    }
  }

  if (result.length > 0) {
    return result;
  }

  const sourceServices = Array.isArray(services) ? services : [];
  const enabledIds = sourceServices
    .filter((service) => service?.enabled !== false)
    .map((service) => String(service?.id || '').trim())
    .filter(Boolean);
  if (enabledIds.length > 0) {
    return enabledIds;
  }

  return sourceServices
    .map((service) => String(service?.id || '').trim())
    .filter(Boolean);
}

function normalizeTimeoutString(value, fallback) {
  const parsed = Number(String(value ?? '').trim());
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return String(fallback);
  }
  return String(Math.floor(parsed));
}

function buildServiceFromEnv(env = {}, overrides = {}) {
  const mergedEnv = mergeEnvWithDefaults(env);
  return {
    id: String(overrides.id || DEFAULT_SERVICE_ID),
    name: String(overrides.name || DEFAULT_SERVICE_NAME),
    enabled: overrides.enabled !== false,
    baseUrl: String(overrides.baseUrl ?? mergedEnv.ANTHROPIC_BASE_URL ?? '').trim(),
    apiKey: String(overrides.apiKey ?? mergedEnv.ANTHROPIC_AUTH_TOKEN ?? '').trim(),
    model: String(overrides.model ?? mergedEnv.ANTHROPIC_MODEL ?? '').trim(),
    targetLanguage: String(overrides.targetLanguage ?? mergedEnv.TARGET_LANGUAGE ?? '').trim(),
    timeoutMs: normalizeTimeoutString(
      overrides.timeoutMs ?? mergedEnv.API_TIMEOUT_MS,
      mergedEnv.API_TIMEOUT_MS
    )
  };
}

function normalizeService(rawService, index, envFallback) {
  const fallback = buildServiceFromEnv(envFallback, {
    id: `svc_${index + 1}`,
    name: `服务 ${index + 1}`
  });

  const id =
    typeof rawService?.id === 'string' && rawService.id.trim()
      ? rawService.id.trim()
      : fallback.id;

  const name =
    typeof rawService?.name === 'string' && rawService.name.trim()
      ? rawService.name.trim()
      : fallback.name;

  const enabled = rawService?.enabled !== false;

  const baseUrl =
    typeof rawService?.baseUrl === 'string' && rawService.baseUrl.trim()
      ? rawService.baseUrl.trim()
      : fallback.baseUrl;

  const apiKey =
    typeof rawService?.apiKey === 'string' ? rawService.apiKey.trim() : fallback.apiKey;

  const model =
    typeof rawService?.model === 'string' && rawService.model.trim()
      ? rawService.model.trim()
      : fallback.model;

  const targetLanguage =
    typeof rawService?.targetLanguage === 'string' && rawService.targetLanguage.trim()
      ? rawService.targetLanguage.trim()
      : fallback.targetLanguage;

  const timeoutMs = normalizeTimeoutString(rawService?.timeoutMs, fallback.timeoutMs);

  return {
    id,
    name,
    enabled,
    baseUrl,
    apiKey,
    model,
    targetLanguage,
    timeoutMs
  };
}

function dedupeServicesById(services) {
  const idCounter = new Map();
  return services.map((service, index) => {
    const baseId = service.id || `svc_${index + 1}`;
    const count = idCounter.get(baseId) || 0;
    idCounter.set(baseId, count + 1);
    if (count === 0) {
      return service;
    }
    return {
      ...service,
      id: `${baseId}_${count + 1}`
    };
  });
}

function getActiveService(services = [], activeServiceId = '') {
  if (!Array.isArray(services) || services.length === 0) {
    return null;
  }

  const byId = services.find((service) => service.id === activeServiceId);
  if (byId?.enabled) {
    return byId;
  }

  const firstEnabled = services.find((service) => service.enabled);
  if (firstEnabled) {
    return firstEnabled;
  }

  return byId || services[0];
}

function normalizeServices(rawSettings, env) {
  const rawServices = Array.isArray(rawSettings?.services) ? rawSettings.services : [];
  let services = rawServices.map((service, index) => normalizeService(service, index, env));

  if (services.length === 0) {
    services = [buildServiceFromEnv(env)];
  }

  services = dedupeServicesById(services);
  const activeService = getActiveService(services, rawSettings?.activeServiceId);
  const activeServiceId = activeService?.id || services[0].id;

  return {
    services,
    activeServiceId
  };
}

function syncEnvWithActiveService(env, services, activeServiceId) {
  const activeService = getActiveService(services, activeServiceId);
  if (!activeService) {
    return env;
  }

  return {
    ...env,
    ANTHROPIC_BASE_URL: activeService.baseUrl,
    ANTHROPIC_AUTH_TOKEN: activeService.apiKey,
    ANTHROPIC_MODEL: activeService.model,
    TARGET_LANGUAGE: activeService.targetLanguage,
    API_TIMEOUT_MS: activeService.timeoutMs
  };
}

function normalizeSettings(rawSettings = {}) {
  const base = {
    ...rawSettings,
    env: mergeEnvWithDefaults(rawSettings?.env || {}),
    routing: normalizeRouting(rawSettings?.routing || {}),
    glossary: normalizeGlossary(rawSettings?.glossary || []),
    automation: normalizeAutomation(rawSettings?.automation || {})
  };

  const { services, activeServiceId } = normalizeServices(base, base.env);
  const syncedEnv = mergeEnvWithDefaults(
    syncEnvWithActiveService(base.env, services, activeServiceId)
  );

  return {
    ...base,
    env: syncedEnv,
    services,
    activeServiceId,
    routing: normalizeRouting(base.routing),
    bubbleVisibleServiceIds: normalizeServiceIdList(base.bubbleVisibleServiceIds, services),
    glossary: normalizeGlossary(base.glossary),
    automation: normalizeAutomation(base.automation)
  };
}

function getConfigDir() {
  return path.join(os.homedir(), CONFIG_DIR_NAME);
}

function getLegacyConfigDir() {
  return path.join(os.homedir(), LEGACY_CONFIG_DIR_NAME);
}

function getSettingsPath() {
  return path.join(getConfigDir(), 'settings.json');
}

function getLegacySettingsPath() {
  return path.join(getLegacyConfigDir(), 'settings.json');
}

function getStatePath() {
  return path.join(os.homedir(), STATE_FILE_NAME);
}

function getLegacyStatePath() {
  return path.join(os.homedir(), LEGACY_STATE_FILE_NAME);
}

function ensureConfigFiles() {
  const configDir = getConfigDir();
  if (!fs.existsSync(configDir)) {
    fs.mkdirSync(configDir, { recursive: true });
  }

  const settingsPath = getSettingsPath();
  const legacySettingsPath = getLegacySettingsPath();
  if (!fs.existsSync(settingsPath)) {
    if (fs.existsSync(legacySettingsPath)) {
      try {
        const legacyRaw = fs.readFileSync(legacySettingsPath, 'utf-8');
        const legacyParsed = JSON.parse(legacyRaw);
        const migrated = normalizeSettings(legacyParsed);
        fs.writeFileSync(settingsPath, JSON.stringify(migrated, null, 2), 'utf-8');
      } catch {
        fs.writeFileSync(settingsPath, JSON.stringify(normalizeSettings(DEFAULT_SETTINGS), null, 2), 'utf-8');
      }
    } else {
      fs.writeFileSync(settingsPath, JSON.stringify(normalizeSettings(DEFAULT_SETTINGS), null, 2), 'utf-8');
    }
  } else {
    try {
      const raw = fs.readFileSync(settingsPath, 'utf-8');
      const parsed = JSON.parse(raw);
      const normalized = normalizeSettings(parsed);
      const normalizedText = JSON.stringify(normalized, null, 2);
      if (raw.trim() !== normalizedText) {
        fs.writeFileSync(settingsPath, normalizedText, 'utf-8');
      }
    } catch {
      fs.writeFileSync(settingsPath, JSON.stringify(normalizeSettings(DEFAULT_SETTINGS), null, 2), 'utf-8');
    }
  }

  const statePath = getStatePath();
  const legacyStatePath = getLegacyStatePath();
  if (!fs.existsSync(statePath)) {
    if (fs.existsSync(legacyStatePath)) {
      try {
        const legacyRaw = fs.readFileSync(legacyStatePath, 'utf-8');
        const legacyParsed = JSON.parse(legacyRaw);
        const migratedState =
          legacyParsed && typeof legacyParsed === 'object'
            ? legacyParsed
            : { hasCompletedOnboarding: true };
        fs.writeFileSync(statePath, JSON.stringify(migratedState, null, 2), 'utf-8');
      } catch {
        fs.writeFileSync(statePath, JSON.stringify({ hasCompletedOnboarding: true }, null, 2), 'utf-8');
      }
    } else {
      fs.writeFileSync(statePath, JSON.stringify({ hasCompletedOnboarding: true }, null, 2), 'utf-8');
    }
  }
}

function readSettings() {
  const settingsPath = getSettingsPath();
  try {
    const raw = fs.readFileSync(settingsPath, 'utf-8');
    const parsed = JSON.parse(raw);
    return normalizeSettings(parsed);
  } catch {
    return normalizeSettings(DEFAULT_SETTINGS);
  }
}

function writeSettings(nextSettings) {
  ensureConfigFiles();
  const normalized = normalizeSettings(nextSettings);
  fs.writeFileSync(getSettingsPath(), JSON.stringify(normalized, null, 2), 'utf-8');
}

function getRuntimeConfig() {
  const settings = readSettings();
  const env = settings.env || {};
  const routing = normalizeRouting(settings.routing || {});
  const glossary = normalizeGlossary(settings.glossary || []);
  const automation = normalizeAutomation(settings.automation || {});
  const activeService = getActiveService(settings.services, settings.activeServiceId);
  const serviceFallback = buildServiceFromEnv(env);
  const serviceConfig = activeService || serviceFallback;

  const baseUrl = serviceConfig.baseUrl || process.env.ANTHROPIC_BASE_URL || env.ANTHROPIC_BASE_URL;
  const apiKey = serviceConfig.apiKey || process.env.ANTHROPIC_AUTH_TOKEN || env.ANTHROPIC_AUTH_TOKEN;
  const model = serviceConfig.model || process.env.ANTHROPIC_MODEL || env.ANTHROPIC_MODEL;
  const targetLanguage =
    serviceConfig.targetLanguage || process.env.TARGET_LANGUAGE || env.TARGET_LANGUAGE || '简体中文';
  const timeoutCandidate = Number(
    serviceConfig.timeoutMs || process.env.API_TIMEOUT_MS || env.API_TIMEOUT_MS || '60000'
  );
  const timeoutMs =
    Number.isFinite(timeoutCandidate) && timeoutCandidate > 0
      ? Math.floor(timeoutCandidate)
      : 60000;
  const translateShortcut =
    process.env.TRANSLATE_SHORTCUT || env.TRANSLATE_SHORTCUT || 'CommandOrControl+Shift+T';
  const openSettingsShortcut =
    process.env.OPEN_SETTINGS_SHORTCUT || env.OPEN_SETTINGS_SHORTCUT || 'CommandOrControl+Shift+O';
  const popupMode = process.env.POPUP_MODE || env.POPUP_MODE || 'panel';
  const fontSize = Number(process.env.TRANSLATOR_FONT_SIZE || env.TRANSLATOR_FONT_SIZE || '16');
  const autoRouteEnabled = parseBooleanEnv(
    process.env.SERVICE_AUTO_ROUTE,
    routing.autoRouteEnabled
  );
  const fallbackEnabled = parseBooleanEnv(
    process.env.SERVICE_FALLBACK_ENABLED,
    routing.fallbackEnabled
  );

  return {
    baseUrl,
    apiKey,
    model,
    targetLanguage,
    timeoutMs,
    services: settings.services || [],
    activeServiceId: settings.activeServiceId || '',
    activeServiceName: serviceConfig.name || '',
    routing: {
      autoRouteEnabled,
      fallbackEnabled
    },
    bubbleVisibleServiceIds: normalizeServiceIdList(
      settings.bubbleVisibleServiceIds,
      settings.services || []
    ),
    glossary,
    automation,
    translateShortcut,
    openSettingsShortcut,
    popupMode,
    fontSize,
    settingsPath: getSettingsPath(),
    statePath: getStatePath()
  };
}

module.exports = {
  DEFAULT_SETTINGS,
  ensureConfigFiles,
  readSettings,
  writeSettings,
  getRuntimeConfig,
  getSettingsPath,
  getStatePath,
  normalizeSettings,
  getActiveService
};
