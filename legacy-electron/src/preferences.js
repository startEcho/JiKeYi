const fieldMap = {
  TRANSLATE_SHORTCUT: document.getElementById('translateShortcut'),
  OPEN_SETTINGS_SHORTCUT: document.getElementById('openSettingsShortcut'),
  POPUP_MODE: document.getElementById('popupMode'),
  TRANSLATOR_FONT_SIZE: document.getElementById('fontSize')
};

const serviceListNode = document.getElementById('serviceList');
const addServiceButton = document.getElementById('addServiceBtn');
const removeServiceButton = document.getElementById('removeServiceBtn');
const setActiveButton = document.getElementById('setActiveBtn');
const activeTagNode = document.getElementById('activeTag');

const serviceFieldMap = {
  name: document.getElementById('serviceName'),
  enabled: document.getElementById('serviceEnabled'),
  baseUrl: document.getElementById('serviceBaseUrl'),
  apiKey: document.getElementById('serviceApiKey'),
  model: document.getElementById('serviceModel'),
  targetLanguage: document.getElementById('serviceTargetLanguage'),
  timeoutMs: document.getElementById('serviceTimeoutMs')
};
const serviceApiKeyPasteButton = document.getElementById('serviceApiKeyPasteBtn');
const serviceApiKeyCopyButton = document.getElementById('serviceApiKeyCopyBtn');
const routingFieldMap = {
  autoRouteEnabled: document.getElementById('autoRouteEnabled')
};
const bubbleServiceListNode = document.getElementById('bubbleServiceList');
const glossaryInput = document.getElementById('glossaryInput');
const automationFieldMap = {
  replaceLineBreaksWithSpace: document.getElementById('replaceLineBreaksWithSpace'),
  stripCodeCommentMarkers: document.getElementById('stripCodeCommentMarkers'),
  removeHyphenSpace: document.getElementById('removeHyphenSpace'),
  autoCopyOcrResult: document.getElementById('autoCopyOcrResult'),
  autoCopyFirstResult: document.getElementById('autoCopyFirstResult'),
  copyHighlightedWordOnClick: document.getElementById('copyHighlightedWordOnClick'),
  autoPlaySourceText: document.getElementById('autoPlaySourceText')
};

const saveButton = document.getElementById('saveBtn');
const openRawButton = document.getElementById('openRawBtn');
const statusNode = document.getElementById('status');
const settingsPathNode = document.getElementById('settingsPath');
const effectiveSummaryNode = document.getElementById('effectiveSummary');
const navItems = Array.from(document.querySelectorAll('.nav-item[data-section-target]'));
const sectionNodes = Array.from(document.querySelectorAll('.pref-section[data-section-id]'));

const shortcutInputs = [
  fieldMap.TRANSLATE_SHORTCUT,
  fieldMap.OPEN_SETTINGS_SHORTCUT
];

const NUMPAD_KEY_MAP = {
  Numpad0: 'num0',
  Numpad1: 'num1',
  Numpad2: 'num2',
  Numpad3: 'num3',
  Numpad4: 'num4',
  Numpad5: 'num5',
  Numpad6: 'num6',
  Numpad7: 'num7',
  Numpad8: 'num8',
  Numpad9: 'num9',
  NumpadAdd: 'numadd',
  NumpadSubtract: 'numsub',
  NumpadMultiply: 'nummult',
  NumpadDivide: 'numdiv',
  NumpadDecimal: 'numdec',
  NumpadEnter: 'Enter'
};

const COMMON_KEY_MAP = {
  Enter: 'Enter',
  Tab: 'Tab',
  Escape: 'Esc',
  Esc: 'Esc',
  Backspace: 'Backspace',
  Delete: 'Delete',
  Insert: 'Insert',
  Home: 'Home',
  End: 'End',
  PageUp: 'PageUp',
  PageDown: 'PageDown',
  ArrowUp: 'Up',
  ArrowDown: 'Down',
  ArrowLeft: 'Left',
  ArrowRight: 'Right',
  ' ': 'Space'
};

const DEFAULT_SERVICE_TEMPLATE = {
  enabled: true,
  baseUrl: 'https://api.minimaxi.com/anthropic',
  apiKey: '',
  model: 'MiniMax-M2.5',
  targetLanguage: '简体中文',
  timeoutMs: '60000'
};

const GLOSSARY_SEPARATORS = ['=>', '->', '→', '：', ':', '='];

let serviceList = [];
let activeServiceId = '';
let selectedServiceId = '';
let bubbleVisibleServiceIds = [];
let isSyncingServiceForm = false;
let activeSectionId = 'services';
let automationSyncTimer = 0;
let automationSyncInFlight = false;
let automationSyncQueued = false;
let hasPendingChanges = false;

function setStatus(text, isError = false) {
  statusNode.textContent = text;
  statusNode.style.color = isError ? '#fda4af' : '#9fb1c8';
}

function markPendingChanges() {
  hasPendingChanges = true;
  setStatus('有未保存修改，按 Cmd/Ctrl+S 或点击“保存并立即生效”');
}

function switchSection(sectionId) {
  const nextSectionId = String(sectionId || '').trim() || 'services';
  activeSectionId = nextSectionId;

  navItems.forEach((item) => {
    const target = item.dataset.sectionTarget || '';
    item.classList.toggle('active', target === nextSectionId);
  });

  sectionNodes.forEach((section) => {
    const id = section.dataset.sectionId || '';
    section.classList.toggle('active', id === nextSectionId);
  });
}

function coerceBoolean(value, fallback) {
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'number') {
    return value !== 0;
  }
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    if (['1', 'true', 'yes', 'on'].includes(normalized)) {
      return true;
    }
    if (['0', 'false', 'no', 'off'].includes(normalized)) {
      return false;
    }
  }
  return fallback;
}

function normalizeRoutingState(rawRouting = {}) {
  return {
    autoRouteEnabled: coerceBoolean(rawRouting?.autoRouteEnabled, true)
  };
}

function normalizeServiceIdList(rawIds, services, fallbackIds = []) {
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

  const enabledIds = (Array.isArray(services) ? services : [])
    .filter((service) => service?.enabled !== false)
    .map((service) => String(service?.id || '').trim())
    .filter(Boolean);
  if (enabledIds.length > 0) {
    return enabledIds;
  }

  const fallback = Array.isArray(fallbackIds)
    ? fallbackIds.map((item) => String(item || '').trim()).filter(Boolean)
    : [];
  if (fallback.length > 0) {
    return fallback;
  }

  return (Array.isArray(services) ? services : [])
    .map((service) => String(service?.id || '').trim())
    .filter(Boolean);
}

function normalizeAutomationState(rawAutomation = {}) {
  return {
    replaceLineBreaksWithSpace: coerceBoolean(rawAutomation?.replaceLineBreaksWithSpace, false),
    stripCodeCommentMarkers: coerceBoolean(rawAutomation?.stripCodeCommentMarkers, false),
    removeHyphenSpace: coerceBoolean(rawAutomation?.removeHyphenSpace, false),
    autoCopyOcrResult: coerceBoolean(rawAutomation?.autoCopyOcrResult, false),
    autoCopyFirstResult: coerceBoolean(rawAutomation?.autoCopyFirstResult, false),
    copyHighlightedWordOnClick: coerceBoolean(rawAutomation?.copyHighlightedWordOnClick, false),
    autoPlaySourceText: coerceBoolean(rawAutomation?.autoPlaySourceText, false)
  };
}

function fillAutomationForm(rawAutomation) {
  const automation = normalizeAutomationState(rawAutomation || {});
  for (const [key, input] of Object.entries(automationFieldMap)) {
    input.checked = Boolean(automation[key]);
  }
}

function collectAutomationPayload() {
  return {
    replaceLineBreaksWithSpace: Boolean(automationFieldMap.replaceLineBreaksWithSpace.checked),
    stripCodeCommentMarkers: Boolean(automationFieldMap.stripCodeCommentMarkers.checked),
    removeHyphenSpace: Boolean(automationFieldMap.removeHyphenSpace.checked),
    autoCopyOcrResult: Boolean(automationFieldMap.autoCopyOcrResult.checked),
    autoCopyFirstResult: Boolean(automationFieldMap.autoCopyFirstResult.checked),
    copyHighlightedWordOnClick: Boolean(automationFieldMap.copyHighlightedWordOnClick.checked),
    autoPlaySourceText: Boolean(automationFieldMap.autoPlaySourceText.checked)
  };
}

function normalizeGlossaryItems(rawGlossary = []) {
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
    result.push({ source, target });
  }
  return result;
}

function splitGlossaryLine(line) {
  const trimmed = String(line || '').trim();
  if (!trimmed) {
    return null;
  }
  if (trimmed.startsWith('#') || trimmed.startsWith('//')) {
    return null;
  }

  for (const separator of GLOSSARY_SEPARATORS) {
    const index = trimmed.indexOf(separator);
    if (index <= 0) {
      continue;
    }

    const source = trimmed.slice(0, index).trim();
    const target = trimmed.slice(index + separator.length).trim();
    if (source && target) {
      return { source, target };
    }
  }

  return { invalid: trimmed };
}

function parseGlossaryText(rawText) {
  const invalidLines = [];
  const items = [];

  String(rawText || '')
    .split(/\r?\n/)
    .forEach((line, index) => {
      const parsed = splitGlossaryLine(line);
      if (!parsed) {
        return;
      }
      if (parsed.invalid) {
        invalidLines.push({
          lineNumber: index + 1,
          text: parsed.invalid
        });
        return;
      }
      items.push(parsed);
    });

  return {
    glossary: normalizeGlossaryItems(items),
    invalidLines
  };
}

function formatGlossaryText(rawGlossary) {
  return normalizeGlossaryItems(rawGlossary)
    .map((item) => `${item.source} => ${item.target}`)
    .join('\n');
}

function cloneService(service) {
  return {
    id: String(service.id || '').trim(),
    name: String(service.name || '').trim(),
    enabled: service.enabled !== false,
    baseUrl: String(service.baseUrl || '').trim(),
    apiKey: String(service.apiKey || '').trim(),
    model: String(service.model || '').trim(),
    targetLanguage: String(service.targetLanguage || '').trim(),
    timeoutMs: String(service.timeoutMs || '').trim()
  };
}

function createServiceId() {
  return `svc_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 7)}`;
}

function createDefaultService(index, reference = null) {
  const seed = reference || DEFAULT_SERVICE_TEMPLATE;
  return {
    id: createServiceId(),
    name: `服务 ${index + 1}`,
    enabled: true,
    baseUrl: String(seed.baseUrl || DEFAULT_SERVICE_TEMPLATE.baseUrl).trim(),
    apiKey: '',
    model: String(seed.model || DEFAULT_SERVICE_TEMPLATE.model).trim(),
    targetLanguage: String(
      seed.targetLanguage || DEFAULT_SERVICE_TEMPLATE.targetLanguage
    ).trim(),
    timeoutMs: String(seed.timeoutMs || DEFAULT_SERVICE_TEMPLATE.timeoutMs).trim()
  };
}

function getServiceById(id) {
  return serviceList.find((service) => service.id === id) || null;
}

function ensureServiceSelection() {
  if (serviceList.length === 0) {
    const created = createDefaultService(0);
    serviceList = [created];
    activeServiceId = created.id;
    selectedServiceId = created.id;
    bubbleVisibleServiceIds = [created.id];
    return;
  }

  const active = getServiceById(activeServiceId);
  if (!active) {
    activeServiceId = serviceList[0].id;
  }

  if (!getServiceById(selectedServiceId)) {
    selectedServiceId = activeServiceId || serviceList[0].id;
  }

  bubbleVisibleServiceIds = normalizeServiceIdList(
    bubbleVisibleServiceIds,
    serviceList,
    [activeServiceId || serviceList[0].id]
  );
}

function renderBubbleServiceList() {
  if (!bubbleServiceListNode) {
    return;
  }

  ensureServiceSelection();
  bubbleServiceListNode.innerHTML = '';

  for (const service of serviceList) {
    const id = String(service.id || '').trim();
    if (!id) {
      continue;
    }

    const label = document.createElement('label');
    label.className = 'bubble-service-item';

    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.value = id;
    checkbox.checked = bubbleVisibleServiceIds.includes(id);

    const nameSpan = document.createElement('span');
    nameSpan.className = 'bubble-service-item-name';
    const serviceName = service.name || service.id || '未命名服务';
    const disabledText = service.enabled === false ? '（停用）' : '';
    nameSpan.textContent = `${serviceName}${disabledText}`;

    label.appendChild(checkbox);
    label.appendChild(nameSpan);
    bubbleServiceListNode.appendChild(label);
  }
}

function renderServiceList() {
  ensureServiceSelection();

  serviceListNode.innerHTML = '';
  for (const service of serviceList) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `service-item${service.id === selectedServiceId ? ' active' : ''}`;
    button.dataset.serviceId = service.id;

    const activeBadge =
      service.id === activeServiceId ? '<span class="tag primary">当前</span>' : '';
    const disabledBadge = service.enabled ? '' : '<span class="tag warn">停用</span>';

    button.innerHTML = `
      <div class="service-item-title">
        <span>${service.name || '未命名服务'}</span>
        <span>${activeBadge}${disabledBadge}</span>
      </div>
      <div class="service-item-meta">${service.model || '(无模型)'} ｜ ${service.baseUrl || '(无地址)'}</div>
    `;

    serviceListNode.appendChild(button);
  }

  removeServiceButton.disabled = serviceList.length <= 1;
  renderBubbleServiceList();
}

function renderServiceEditor() {
  const current = getServiceById(selectedServiceId);
  const disabled = !current;
  isSyncingServiceForm = true;

  if (!current) {
    serviceFieldMap.name.value = '';
    serviceFieldMap.enabled.checked = false;
    serviceFieldMap.baseUrl.value = '';
    serviceFieldMap.apiKey.value = '';
    serviceFieldMap.model.value = '';
    serviceFieldMap.targetLanguage.value = '';
    serviceFieldMap.timeoutMs.value = '';
  } else {
    serviceFieldMap.name.value = current.name || '';
    serviceFieldMap.enabled.checked = current.enabled !== false;
    serviceFieldMap.baseUrl.value = current.baseUrl || '';
    serviceFieldMap.apiKey.value = current.apiKey || '';
    serviceFieldMap.model.value = current.model || '';
    serviceFieldMap.targetLanguage.value = current.targetLanguage || '';
    serviceFieldMap.timeoutMs.value = current.timeoutMs || '';
  }

  for (const input of Object.values(serviceFieldMap)) {
    input.disabled = disabled;
  }
  if (serviceApiKeyPasteButton) {
    serviceApiKeyPasteButton.disabled = disabled;
  }
  if (serviceApiKeyCopyButton) {
    serviceApiKeyCopyButton.disabled = disabled;
  }

  const isCurrentActive = current && current.id === activeServiceId;
  activeTagNode.style.visibility = isCurrentActive ? 'visible' : 'hidden';
  setActiveButton.disabled = disabled || isCurrentActive;
  isSyncingServiceForm = false;
}

function getInputSelectionRange(input) {
  const rawValue = String(input?.value || '');
  const length = rawValue.length;
  const rawStart = Number(input?.selectionStart);
  const rawEnd = Number(input?.selectionEnd);
  const start = Number.isFinite(rawStart) ? Math.max(0, Math.min(length, rawStart)) : length;
  const end = Number.isFinite(rawEnd) ? Math.max(0, Math.min(length, rawEnd)) : start;
  return {
    start: Math.min(start, end),
    end: Math.max(start, end),
    length
  };
}

async function readClipboardTextSafe() {
  if (window.preferencesApi?.readClipboardText) {
    try {
      return String((await window.preferencesApi.readClipboardText()) || '');
    } catch {
      // Fallback below.
    }
  }

  if (navigator.clipboard?.readText) {
    try {
      return String((await navigator.clipboard.readText()) || '');
    } catch {
      // Ignore clipboard fallback errors.
    }
  }

  return '';
}

async function writeClipboardTextSafe(text) {
  const value = String(text || '');
  if (window.preferencesApi?.writeClipboardText) {
    try {
      await window.preferencesApi.writeClipboardText(value);
      return true;
    } catch {
      // Fallback below.
    }
  }

  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(value);
      return true;
    } catch {
      // Ignore clipboard fallback errors.
    }
  }

  return false;
}

async function copyApiKeyToClipboard(options = {}) {
  const { preferSelection = false } = options;
  const input = serviceFieldMap.apiKey;
  if (!input || input.disabled) {
    return;
  }

  const value = String(input.value || '');
  if (!value) {
    setStatus('API Key 为空，无法复制', true);
    return;
  }

  const range = getInputSelectionRange(input);
  const hasSelection = range.end > range.start;
  const textToCopy = hasSelection
    ? value.slice(range.start, range.end)
    : preferSelection
      ? ''
      : value;

  if (!textToCopy) {
    return;
  }

  const ok = await writeClipboardTextSafe(textToCopy);
  if (ok) {
    setStatus('API Key 已复制');
    return;
  }
  setStatus('复制失败：无法写入剪贴板', true);
}

async function pasteApiKeyFromClipboard() {
  const input = serviceFieldMap.apiKey;
  if (!input || input.disabled) {
    return;
  }

  const pasted = await readClipboardTextSafe();
  if (!pasted) {
    setStatus('粘贴失败：剪贴板为空或不可读', true);
    return;
  }

  const value = String(input.value || '');
  const range = getInputSelectionRange(input);
  input.value = `${value.slice(0, range.start)}${pasted}${value.slice(range.end)}`;
  const cursor = range.start + pasted.length;
  try {
    input.setSelectionRange(cursor, cursor);
  } catch {
    // Ignore selection API errors.
  }

  updateSelectedServiceFromForm();
  setStatus('API Key 已粘贴');
}

async function cutApiKeyToClipboard() {
  const input = serviceFieldMap.apiKey;
  if (!input || input.disabled) {
    return;
  }

  const value = String(input.value || '');
  const range = getInputSelectionRange(input);
  if (!value || range.end <= range.start) {
    return;
  }

  const selectedText = value.slice(range.start, range.end);
  const ok = await writeClipboardTextSafe(selectedText);
  if (!ok) {
    setStatus('剪切失败：无法写入剪贴板', true);
    return;
  }

  input.value = `${value.slice(0, range.start)}${value.slice(range.end)}`;
  try {
    input.setSelectionRange(range.start, range.start);
  } catch {
    // Ignore selection API errors.
  }
  updateSelectedServiceFromForm();
  setStatus('API Key 已剪切');
}

function renderEffectiveSummary(effective = {}) {
  const activeServiceName = effective.activeServiceName || '未设置';
  effectiveSummaryNode.textContent =
    `当前生效：服务 ${activeServiceName} ｜ 翻译 ${effective.translateShortcut} ｜ 偏好设置 ${effective.openSettingsShortcut} ｜ 模式 ${effective.popupMode} ｜ 字体 ${effective.fontSize}px`;
}

function fillGlobalForm(env) {
  for (const key of Object.keys(fieldMap)) {
    fieldMap[key].value = env[key] || '';
  }
}

function loadResponseIntoState(data) {
  fillGlobalForm(data.env || {});
  serviceList = Array.isArray(data.services) ? data.services.map(cloneService) : [];
  activeServiceId = String(data.activeServiceId || '').trim();
  selectedServiceId = activeServiceId;
  bubbleVisibleServiceIds = normalizeServiceIdList(
    data.bubbleVisibleServiceIds,
    serviceList,
    [activeServiceId]
  );
  const routing = normalizeRoutingState(data.routing || {});
  routingFieldMap.autoRouteEnabled.checked = routing.autoRouteEnabled;
  glossaryInput.value = formatGlossaryText(data.glossary || []);
  fillAutomationForm(data.automation || {});
  settingsPathNode.textContent = data.settingsPath || '';
  renderEffectiveSummary(data.effective || {});
  ensureServiceSelection();
  renderServiceList();
  renderServiceEditor();
}

function collectGlobalPayload() {
  const env = {};
  for (const [key, input] of Object.entries(fieldMap)) {
    env[key] = String(input.value ?? '').trim();
  }
  return env;
}

function validateServices() {
  if (!Array.isArray(serviceList) || serviceList.length === 0) {
    return '至少保留一个服务';
  }

  for (const service of serviceList) {
    if (!service.baseUrl) {
      return `服务「${service.name || service.id}」缺少 Base URL`;
    }
    if (!service.model) {
      return `服务「${service.name || service.id}」缺少模型名`;
    }
    const timeout = Number(service.timeoutMs);
    if (!Number.isFinite(timeout) || timeout <= 0) {
      return `服务「${service.name || service.id}」超时必须是正数`;
    }
  }

  return '';
}

function collectPayload() {
  const active =
    getServiceById(activeServiceId) ||
    serviceList.find((service) => service.enabled) ||
    serviceList[0];
  const normalizedBubbleIds = normalizeServiceIdList(
    bubbleVisibleServiceIds,
    serviceList,
    [active?.id || serviceList[0]?.id || '']
  );
  const parsedGlossary = parseGlossaryText(glossaryInput.value || '');

  return {
    env: collectGlobalPayload(),
    services: serviceList.map(cloneService),
    activeServiceId: active?.id || '',
    routing: {
      autoRouteEnabled: Boolean(routingFieldMap.autoRouteEnabled.checked)
    },
    bubbleVisibleServiceIds: normalizedBubbleIds,
    glossary: parsedGlossary.glossary,
    automation: collectAutomationPayload()
  };
}

function validateGlossary() {
  const parsed = parseGlossaryText(glossaryInput.value || '');
  if (parsed.invalidLines.length === 0) {
    return '';
  }

  const previews = parsed.invalidLines
    .slice(0, 2)
    .map((item) => `第 ${item.lineNumber} 行`)
    .join('、');
  return `术语表格式错误（${previews}）：请使用“原词 => 译法”`;
}

function updateSelectedServiceFromForm() {
  if (isSyncingServiceForm) {
    return;
  }

  const current = getServiceById(selectedServiceId);
  if (!current) {
    return;
  }

  current.name = String(serviceFieldMap.name.value || '').trim();
  current.enabled = Boolean(serviceFieldMap.enabled.checked);
  current.baseUrl = String(serviceFieldMap.baseUrl.value || '').trim();
  current.apiKey = String(serviceFieldMap.apiKey.value || '').trim();
  current.model = String(serviceFieldMap.model.value || '').trim();
  current.targetLanguage = String(serviceFieldMap.targetLanguage.value || '').trim();
  current.timeoutMs = String(serviceFieldMap.timeoutMs.value || '').trim();

  renderServiceList();
}

function isModifierKey(event) {
  return ['Meta', 'Control', 'Alt', 'Shift'].includes(event.key);
}

function keyFromKeyboardEvent(event) {
  const { code, key } = event;

  if (code?.startsWith('Key')) {
    return code.slice(3).toUpperCase();
  }

  if (code?.startsWith('Digit')) {
    return code.slice(5);
  }

  if (code && /^F\d{1,2}$/i.test(code)) {
    return code.toUpperCase();
  }

  if (code && NUMPAD_KEY_MAP[code]) {
    return NUMPAD_KEY_MAP[code];
  }

  if (COMMON_KEY_MAP[key]) {
    return COMMON_KEY_MAP[key];
  }

  if (typeof key === 'string' && key.length === 1 && /[a-z0-9]/i.test(key)) {
    return key.toUpperCase();
  }

  return '';
}

function acceleratorFromKeyboardEvent(event) {
  const modifiers = [];

  if (event.metaKey || event.ctrlKey) {
    modifiers.push('CommandOrControl');
  }
  if (event.altKey) {
    modifiers.push('Alt');
  }
  if (event.shiftKey) {
    modifiers.push('Shift');
  }

  if (modifiers.length === 0) {
    return '';
  }

  const key = keyFromKeyboardEvent(event);
  if (!key) {
    return '';
  }

  return [...new Set(modifiers), key].join('+');
}

function bindShortcutRecorder(input) {
  input.addEventListener('focus', () => {
    setStatus('录制中：请按下快捷键组合');
  });

  input.addEventListener('blur', () => {
    setStatus('等待操作');
  });

  input.addEventListener('keydown', (event) => {
    event.preventDefault();
    event.stopPropagation();

    if (event.key === 'Backspace' || event.key === 'Delete') {
      input.value = '';
      setStatus('快捷键已清空，可直接保存');
      return;
    }

    if (isModifierKey(event)) {
      setStatus('请继续按下主键（如 T / O / F1）');
      return;
    }

    const accelerator = acceleratorFromKeyboardEvent(event);
    if (!accelerator) {
      setStatus('无效组合：请至少包含修饰键 + 主键', true);
      return;
    }

    input.value = accelerator;
    setStatus(`已录入：${accelerator}`);
  });
}

function setupShortcutRecorders() {
  shortcutInputs.forEach((input) => {
    bindShortcutRecorder(input);
  });
}

async function loadSettings() {
  setStatus('正在读取配置...');
  try {
    const data = await window.preferencesApi.getSettings();
    loadResponseIntoState(data);
    hasPendingChanges = false;
    setStatus('已加载');
  } catch (error) {
    setStatus(`读取失败：${error.message || error}`, true);
  }
}

async function saveSettings() {
  const validationError = validateServices();
  if (validationError) {
    setStatus(validationError, true);
    return;
  }

  const glossaryError = validateGlossary();
  if (glossaryError) {
    setStatus(glossaryError, true);
    return;
  }

  saveButton.disabled = true;
  setStatus('保存中...');

  try {
    const result = await window.preferencesApi.saveSettings(collectPayload());
    loadResponseIntoState(result);
    hasPendingChanges = false;
    setStatus('保存成功，已生效');
  } catch (error) {
    setStatus(`保存失败：${error.message || error}`, true);
  } finally {
    saveButton.disabled = false;
  }
}

function clearAutomationSyncTimer() {
  if (!automationSyncTimer) {
    return;
  }
  clearTimeout(automationSyncTimer);
  automationSyncTimer = 0;
}

async function flushAutomationSync() {
  if (!window.preferencesApi?.updateAutomation) {
    setStatus('自动化设置已修改，请点击保存后生效');
    return;
  }
  if (automationSyncInFlight) {
    automationSyncQueued = true;
    return;
  }

  automationSyncInFlight = true;
  try {
    const result = await window.preferencesApi.updateAutomation(collectAutomationPayload());
    if (result?.automation) {
      fillAutomationForm(result.automation);
    }
    setStatus('自动化设置已生效');
  } catch (error) {
    setStatus(`自动化设置应用失败：${error.message || error}`, true);
  } finally {
    automationSyncInFlight = false;
    if (automationSyncQueued) {
      automationSyncQueued = false;
      await flushAutomationSync();
    }
  }
}

function scheduleAutomationSync() {
  clearAutomationSyncTimer();
  automationSyncTimer = window.setTimeout(() => {
    automationSyncTimer = 0;
    flushAutomationSync();
  }, 120);
}

addServiceButton.addEventListener('click', () => {
  const reference = getServiceById(selectedServiceId) || serviceList[serviceList.length - 1];
  const next = createDefaultService(serviceList.length, reference);
  serviceList.push(next);
  bubbleVisibleServiceIds = normalizeServiceIdList(
    [...bubbleVisibleServiceIds, next.id],
    serviceList,
    [activeServiceId || next.id]
  );
  selectedServiceId = next.id;
  renderServiceList();
  renderServiceEditor();
  markPendingChanges();
  setStatus(`已新增服务：${next.name}`);
});

removeServiceButton.addEventListener('click', () => {
  if (serviceList.length <= 1) {
    setStatus('至少保留一个服务', true);
    return;
  }

  const previousSelected = selectedServiceId;
  serviceList = serviceList.filter((service) => service.id !== previousSelected);
  bubbleVisibleServiceIds = bubbleVisibleServiceIds.filter((id) => id !== previousSelected);
  if (activeServiceId === previousSelected) {
    const fallback =
      serviceList.find((service) => service.enabled) ||
      serviceList[0];
    activeServiceId = fallback.id;
  }

  selectedServiceId = activeServiceId || serviceList[0].id;
  renderServiceList();
  renderServiceEditor();
  markPendingChanges();
  setStatus('已删除当前服务');
});

setActiveButton.addEventListener('click', async () => {
  const selected = getServiceById(selectedServiceId);
  if (!selected) {
    return;
  }

  activeServiceId = selected.id;
  renderServiceList();
  renderServiceEditor();
  markPendingChanges();
  setStatus(`已设为当前服务：${selected.name}，正在应用...`);
  await saveSettings();
});

serviceListNode.addEventListener('click', (event) => {
  const target = event.target.closest('.service-item');
  if (!target) {
    return;
  }
  selectedServiceId = String(target.dataset.serviceId || '');
  renderServiceList();
  renderServiceEditor();
});

bubbleServiceListNode?.addEventListener('change', () => {
  const checkedIds = Array.from(
    bubbleServiceListNode.querySelectorAll('input[type="checkbox"]:checked')
  )
    .map((node) => String(node.value || '').trim())
    .filter(Boolean);

  if (checkedIds.length === 0) {
    bubbleVisibleServiceIds = normalizeServiceIdList([], serviceList, [activeServiceId]);
    renderBubbleServiceList();
    setStatus('气泡显示服务不能全空，已自动恢复为全部启用服务');
    return;
  }

  bubbleVisibleServiceIds = normalizeServiceIdList(checkedIds, serviceList, [activeServiceId]);
  markPendingChanges();
});

for (const input of Object.values(serviceFieldMap)) {
  const eventName = input.type === 'checkbox' ? 'change' : 'input';
  input.addEventListener(eventName, () => {
    updateSelectedServiceFromForm();
    markPendingChanges();
    if (input.type === 'checkbox') {
      renderServiceEditor();
    }
  });
}

serviceFieldMap.apiKey?.addEventListener('keydown', async (event) => {
  const withPrimaryModifier = event.metaKey || event.ctrlKey;
  if (!withPrimaryModifier || event.altKey) {
    return;
  }

  const key = String(event.key || '').toLowerCase();
  if (key === 'v') {
    event.preventDefault();
    await pasteApiKeyFromClipboard();
    return;
  }
  if (key === 'c') {
    event.preventDefault();
    await copyApiKeyToClipboard({ preferSelection: true });
    return;
  }
  if (key === 'x') {
    event.preventDefault();
    await cutApiKeyToClipboard();
  }
});

serviceApiKeyPasteButton?.addEventListener('click', () => {
  pasteApiKeyFromClipboard();
});

serviceApiKeyCopyButton?.addEventListener('click', () => {
  copyApiKeyToClipboard({ preferSelection: false });
});

for (const input of Object.values(automationFieldMap)) {
  input.addEventListener('change', () => {
    markPendingChanges();
    scheduleAutomationSync();
  });
}

routingFieldMap.autoRouteEnabled?.addEventListener('change', () => {
  markPendingChanges();
});

glossaryInput?.addEventListener('input', () => {
  markPendingChanges();
});

for (const input of Object.values(fieldMap)) {
  input.addEventListener('input', () => {
    markPendingChanges();
  });
}

saveButton.addEventListener('click', () => {
  saveSettings();
});

openRawButton.addEventListener('click', async () => {
  await window.preferencesApi.openRawSettingsFile();
});

navItems.forEach((item) => {
  item.addEventListener('click', () => {
    switchSection(item.dataset.sectionTarget || 'services');
  });
});

window.addEventListener('DOMContentLoaded', () => {
  switchSection(activeSectionId);
  setupShortcutRecorders();
  loadSettings();
});

window.addEventListener('keydown', (event) => {
  const withPrimaryModifier = event.metaKey || event.ctrlKey;
  if (!withPrimaryModifier || event.altKey) {
    return;
  }
  const key = String(event.key || '').toLowerCase();
  if (key !== 's') {
    return;
  }

  event.preventDefault();
  saveSettings();
});
