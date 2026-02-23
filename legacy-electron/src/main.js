const {
  app,
  BrowserWindow,
  clipboard,
  globalShortcut,
  Menu,
  Notification,
  Tray,
  screen,
  shell,
  ipcMain
} = require('electron');
const fs = require('node:fs');
const { execFile, spawn } = require('node:child_process');
const path = require('node:path');
const { promisify } = require('node:util');
const {
  DEFAULT_SETTINGS,
  ensureConfigFiles,
  getActiveService,
  getRuntimeConfig,
  getSettingsPath,
  readSettings,
  writeSettings
} = require('./config');
const { translateText, streamTranslateText } = require('./translator');
const { createTrayIcon } = require('./tray-icon');

const execFileAsync = promisify(execFile);
const APP_NAME = '即刻译';

const TRANSLATOR_WINDOW_PRESETS = {
  panel: {
    defaultWidth: 920,
    defaultHeight: 680,
    minWidth: 760,
    minHeight: 520
  },
  bubble: {
    defaultWidth: 660,
    defaultHeight: 540,
    minWidth: 520,
    minHeight: 380
  }
};

const POPUP_MARGIN = 18;
const AUTO_COPY_COMMAND_TIMEOUT_MS = 1400;
const AUTO_COPY_FIRST_WAIT_MS = 170;
const AUTO_COPY_RETRY_WAIT_MS = 360;
const AUTO_COPY_POLL_INTERVAL_MS = 12;
const AUTO_COPY_TRIGGER_DELAY_MS = 10;
const AUTO_COPY_RETRY_DELAY_MS = 80;
const AUTO_COPY_MAX_ATTEMPTS = 3;
const BUBBLE_BLUR_HIDE_DELAY_MS = 46;
const BUBBLE_OUTSIDE_WATCH_INTERVAL_MS = 120;
const BUBBLE_OUTSIDE_WATCH_ARM_DELAY_MS = 420;
const BUBBLE_OUTSIDE_WATCH_STREAK = 3;
const MAC_SELECTION_HELPER_BUILD_TIMEOUT_MS = 20000;
const MAC_SELECTION_HELPER_READ_TIMEOUT_MS = 540;
const MAC_SELECTION_HELPER_PROBE_WAIT_MS = 110;
const MAC_SELECTION_HELPER_BUILD_RETRY_COOLDOWN_MS = 12000;
const MAC_COPY_HELPER_BUILD_TIMEOUT_MS = 20000;
const MAC_COPY_HELPER_BUILD_RETRY_COOLDOWN_MS = 12000;
const MAC_CLICK_MONITOR_BUILD_TIMEOUT_MS = 20000;
const MAC_CLICK_MONITOR_RESTART_DELAY_MS = 800;
const MAC_HELPER_PERMISSION_RETRY_COOLDOWN_MS = 60000;
const SERVICE_ROUTE_INITIAL_LATENCY_MS = 760;
const SERVICE_ROUTE_EWMA_ALPHA = 0.35;
const SERVICE_ROUTE_FAILURE_PENALTY_MS = 320;
const SERVICE_ROUTE_TIMEOUT_PENALTY_MS = 560;
const SERVICE_ROUTE_DISABLED_PENALTY_MS = 2200;
const SERVICE_STREAM_UPDATE_THROTTLE_MS = 78;

const DEFAULT_SHORTCUTS = {
  translateShortcut: 'CommandOrControl+Shift+T',
  openSettingsShortcut: 'CommandOrControl+Shift+O'
};

const MODIFIER_TOKENS = new Set([
  'commandorcontrol',
  'command',
  'cmd',
  'control',
  'ctrl',
  'alt',
  'option',
  'shift',
  'super'
]);

const GLOBAL_ENV_SETTING_KEYS = [
  'TRANSLATE_SHORTCUT',
  'OPEN_SETTINGS_SHORTCUT',
  'POPUP_MODE',
  'TRANSLATOR_FONT_SIZE'
];

let mainWindow;
let preferencesWindow;
let tray;
let runtimeConfig;
let translationInProgress = false;
let isQuitting = false;
let isMainWindowReady = false;
let pendingTranslationPayload = null;
let mainWindowPopupMode = null;
let shortcutRegistrationResult = {
  translateShortcut: null,
  openSettingsShortcut: null
};
let macSelectionHelperPath = null;
let macSelectionHelperBuildPromise = null;
let macSelectionHelperUnavailable = false;
let macSelectionHelperRetryAfter = 0;
let macCopyHelperPath = null;
let macCopyHelperBuildPromise = null;
let macCopyHelperUnavailable = false;
let macCopyHelperRetryAfter = 0;
let macClickMonitorHelperPath = null;
let macClickMonitorBuildPromise = null;
let macClickMonitorUnavailable = false;
let macClickMonitorProcess = null;
let macClickMonitorStdoutBuffer = '';
let macClickMonitorRestartTimer = null;
let macClickMonitorPermissionNotified = false;
const serviceRoutingMetrics = new Map();
let bubbleDismissedByBlur = false;
let bubbleHideTimer = null;
let bubbleOutsideWatchTimer = null;
let bubbleOutsideWatchStreak = 0;
let bubbleFocusedSinceShown = false;
let selectionReadInProgress = false;
let mainWindowShownAt = 0;
let latestSelectionAnchor = null;
let bubblePinned = false;

const gotSingleInstanceLock = app.requestSingleInstanceLock();
if (!gotSingleInstanceLock) {
  app.quit();
}

function normalizeShortcut(shortcut, fallback) {
  if (typeof shortcut !== 'string') {
    return fallback;
  }
  const value = shortcut.trim();
  return value || fallback;
}

function normalizePopupMode(mode) {
  const value = String(mode || '')
    .trim()
    .toLowerCase();
  return value === 'bubble' ? 'bubble' : 'panel';
}

function normalizeFontSize(size) {
  const parsed = Number(size);
  if (!Number.isFinite(parsed)) {
    return 16;
  }
  return clampToRange(Math.round(parsed), 12, 32);
}

function getTranslatorWindowPreset(popupMode) {
  return TRANSLATOR_WINDOW_PRESETS[popupMode] || TRANSLATOR_WINDOW_PRESETS.panel;
}

function normalizeRuntimeConfig(config) {
  return {
    ...config,
    translateShortcut: normalizeShortcut(
      config.translateShortcut,
      DEFAULT_SHORTCUTS.translateShortcut
    ),
    openSettingsShortcut: normalizeShortcut(
      config.openSettingsShortcut,
      DEFAULT_SHORTCUTS.openSettingsShortcut
    ),
    popupMode: normalizePopupMode(config.popupMode),
    fontSize: normalizeFontSize(config.fontSize)
  };
}

function loadRuntimeConfig() {
  runtimeConfig = normalizeRuntimeConfig(getRuntimeConfig());
}

function isBubbleMode() {
  return (runtimeConfig?.popupMode || 'panel') === 'bubble';
}

function emitBubblePinStateToRenderer() {
  if (!mainWindow || mainWindow.isDestroyed()) {
    return;
  }

  mainWindow.webContents.send('bubble-pin-updated', {
    pinned: bubblePinned === true,
    available: isBubbleMode()
  });
}

function setBubblePinned(nextPinned) {
  const shouldPin = isBubbleMode() && nextPinned === true;
  if (bubblePinned === shouldPin) {
    emitBubblePinStateToRenderer();
    return;
  }

  bubblePinned = shouldPin;
  if (bubblePinned && bubbleHideTimer) {
    clearTimeout(bubbleHideTimer);
    bubbleHideTimer = null;
  }
  if (bubblePinned) {
    bubbleDismissedByBlur = false;
    stopBubbleOutsideWatch();
    stopMacGlobalClickMonitor();
  } else if (mainWindow && !mainWindow.isDestroyed() && mainWindow.isVisible()) {
    bubbleFocusedSinceShown = true;
    startBubbleOutsideWatch();
    startMacGlobalClickMonitorIfNeeded();
  }

  emitBubblePinStateToRenderer();
}

function stopBubbleOutsideWatch() {
  if (bubbleOutsideWatchTimer) {
    clearInterval(bubbleOutsideWatchTimer);
    bubbleOutsideWatchTimer = null;
  }
  bubbleOutsideWatchStreak = 0;
}

function hideBubbleWindow(options = {}) {
  const markDismissed = options?.markDismissed !== false;
  const force = options?.force === true;
  if (!mainWindow || mainWindow.isDestroyed() || !mainWindow.isVisible()) {
    return;
  }
  if (!isBubbleMode() || bubblePinned) {
    return;
  }
  if (!force && selectionReadInProgress) {
    return;
  }

  if (markDismissed) {
    bubbleDismissedByBlur = true;
  }
  mainWindow.webContents.send('window-visibility', { visible: false });
  if (bubbleHideTimer) {
    clearTimeout(bubbleHideTimer);
  }
  bubbleHideTimer = setTimeout(() => {
    bubbleHideTimer = null;
    if (mainWindow && !mainWindow.isDestroyed() && mainWindow.isVisible()) {
      mainWindow.hide();
    }
    bubbleFocusedSinceShown = false;
    stopBubbleOutsideWatch();
    stopMacGlobalClickMonitor();
  }, BUBBLE_BLUR_HIDE_DELAY_MS);
}

function startBubbleOutsideWatch() {
  if (bubbleOutsideWatchTimer) {
    return;
  }

  bubbleOutsideWatchStreak = 0;
  bubbleOutsideWatchTimer = setInterval(() => {
    if (!mainWindow || mainWindow.isDestroyed()) {
      stopBubbleOutsideWatch();
      return;
    }
    if (!isBubbleMode() || bubblePinned || !mainWindow.isVisible()) {
      bubbleOutsideWatchStreak = 0;
      return;
    }
    if (selectionReadInProgress) {
      bubbleOutsideWatchStreak = 0;
      return;
    }
    if (!bubbleFocusedSinceShown) {
      bubbleOutsideWatchStreak = 0;
      return;
    }
    if (bubbleHideTimer) {
      return;
    }
    if (Date.now() - mainWindowShownAt < BUBBLE_OUTSIDE_WATCH_ARM_DELAY_MS) {
      return;
    }
    if (!mainWindow.isFocused() && Date.now() - mainWindowShownAt < 900) {
      return;
    }

    const cursorPoint = screen.getCursorScreenPoint();
    const bounds = mainWindow.getBounds();
    const pointerInsideWindow = isPointInsideBounds(cursorPoint, bounds);
    if (mainWindow.isFocused() || pointerInsideWindow) {
      bubbleOutsideWatchStreak = 0;
      return;
    }

    bubbleOutsideWatchStreak += 1;
    if (bubbleOutsideWatchStreak < BUBBLE_OUTSIDE_WATCH_STREAK) {
      return;
    }

    bubbleOutsideWatchStreak = 0;
    hideBubbleWindow({ markDismissed: true });
  }, BUBBLE_OUTSIDE_WATCH_INTERVAL_MS);
}

function clearMacClickMonitorRestartTimer() {
  if (macClickMonitorRestartTimer) {
    clearTimeout(macClickMonitorRestartTimer);
    macClickMonitorRestartTimer = null;
  }
}

function shouldRunMacGlobalClickMonitor() {
  return (
    process.platform === 'darwin' &&
    isBubbleMode() &&
    !bubblePinned &&
    !selectionReadInProgress &&
    mainWindow &&
    !mainWindow.isDestroyed() &&
    mainWindow.isVisible()
  );
}

function stopMacGlobalClickMonitor() {
  clearMacClickMonitorRestartTimer();
  macClickMonitorStdoutBuffer = '';

  if (!macClickMonitorProcess) {
    return;
  }

  const processRef = macClickMonitorProcess;
  macClickMonitorProcess = null;

  try {
    processRef.removeAllListeners();
    processRef.stdout?.removeAllListeners();
    processRef.stderr?.removeAllListeners();
    processRef.kill('SIGTERM');
  } catch {
    // Ignore stop failures on process teardown.
  }
}

function handleGlobalClickFromNativeMonitor() {
  if (
    !mainWindow ||
    mainWindow.isDestroyed() ||
    !mainWindow.isVisible() ||
    !isBubbleMode() ||
    bubblePinned
  ) {
    return;
  }

  if (bubbleHideTimer) {
    return;
  }

  const cursorPoint = screen.getCursorScreenPoint();
  const bounds = mainWindow.getBounds();
  if (isPointInsideBounds(cursorPoint, bounds)) {
    return;
  }

  hideBubbleWindow({ markDismissed: true, force: true });
}

function consumeMacClickMonitorLine(line) {
  const normalizedLine = String(line || '').trim();
  if (!normalizedLine) {
    return;
  }

  let payload = null;
  try {
    payload = JSON.parse(normalizedLine);
  } catch {
    return;
  }

  const type = String(payload?.type || '').toLowerCase();
  if (type !== 'mouse_down') {
    return;
  }

  handleGlobalClickFromNativeMonitor();
}

function scheduleMacGlobalClickMonitorRestart() {
  if (macClickMonitorRestartTimer || isQuitting) {
    return;
  }

  if (!shouldRunMacGlobalClickMonitor()) {
    return;
  }

  macClickMonitorRestartTimer = setTimeout(() => {
    macClickMonitorRestartTimer = null;
    startMacGlobalClickMonitorIfNeeded();
  }, MAC_CLICK_MONITOR_RESTART_DELAY_MS);
}

async function startMacGlobalClickMonitorIfNeeded() {
  if (!shouldRunMacGlobalClickMonitor()) {
    stopMacGlobalClickMonitor();
    return;
  }

  if (macClickMonitorProcess || macClickMonitorUnavailable) {
    return;
  }

  clearMacClickMonitorRestartTimer();
  const helperPath = macClickMonitorHelperPath || (await ensureMacClickMonitorHelperBuilt());
  if (!helperPath) {
    return;
  }

  const child = spawn(helperPath, [], {
    stdio: ['ignore', 'pipe', 'pipe']
  });
  macClickMonitorProcess = child;
  macClickMonitorStdoutBuffer = '';

  child.stdout?.on('data', (chunk) => {
    macClickMonitorStdoutBuffer += chunk.toString('utf8');
    let delimiterIndex = macClickMonitorStdoutBuffer.indexOf('\n');
    while (delimiterIndex !== -1) {
      const line = macClickMonitorStdoutBuffer.slice(0, delimiterIndex);
      macClickMonitorStdoutBuffer = macClickMonitorStdoutBuffer.slice(delimiterIndex + 1);
      consumeMacClickMonitorLine(line);
      delimiterIndex = macClickMonitorStdoutBuffer.indexOf('\n');
    }
  });

  child.stderr?.on('data', (chunk) => {
    const message = String(chunk || '').toLowerCase();
    if (message.includes('accessibility_denied') || message.includes('ax_not_trusted')) {
      if (!macClickMonitorPermissionNotified) {
        macClickMonitorPermissionNotified = true;
        showNotification(
          APP_NAME,
          '全局点击监听未授权：请检查“辅助功能”权限，气泡外点关闭可能不稳定。'
        );
      }
      macClickMonitorUnavailable = true;
    }
  });

  child.on('error', () => {
    if (macClickMonitorProcess === child) {
      macClickMonitorProcess = null;
    }
    scheduleMacGlobalClickMonitorRestart();
  });

  child.on('exit', () => {
    if (macClickMonitorProcess === child) {
      macClickMonitorProcess = null;
    }
    macClickMonitorStdoutBuffer = '';
    scheduleMacGlobalClickMonitorRestart();
  });
}

function currentTranslateShortcut() {
  return shortcutRegistrationResult.translateShortcut || runtimeConfig.translateShortcut;
}

function currentOpenSettingsShortcut() {
  return shortcutRegistrationResult.openSettingsShortcut || runtimeConfig.openSettingsShortcut;
}

function ensureMainWindowForCurrentMode() {
  const desiredMode = runtimeConfig?.popupMode || 'panel';

  if (!mainWindow || mainWindow.isDestroyed()) {
    createMainWindow();
    return;
  }

  if (mainWindowPopupMode === desiredMode) {
    return;
  }

  const wasVisible = mainWindow.isVisible();
  mainWindow.destroy();
  createMainWindow();

  if (wasVisible) {
    placeTranslatorWindowOnActiveDisplay();
    mainWindow.show();
  }
}

function openTranslatorWindow(options = {}) {
  const { focus = true, anchor = null } = options;
  ensureMainWindowForCurrentMode();
  const bubbleMode = (runtimeConfig?.popupMode || 'panel') === 'bubble';
  if (bubbleMode) {
    bubbleOutsideWatchStreak = 0;
    if (focus) {
      bubbleFocusedSinceShown = false;
    }
  }

  if (bubbleHideTimer) {
    clearTimeout(bubbleHideTimer);
    bubbleHideTimer = null;
  }
  if (!bubbleMode || !focus) {
    stopBubbleOutsideWatch();
  }

  applyTranslatorWindowMode();
  placeTranslatorWindowOnActiveDisplay({ anchor });

  if (focus) {
    mainWindow.show();
    if (bubbleMode) {
      mainWindow.focus();
    } else {
      if (process.platform === 'darwin') {
        app.focus({ steal: true });
      } else {
        app.focus();
      }
      mainWindow.focus();
    }
    mainWindowShownAt = Date.now();
    if (bubbleMode) {
      mainWindow.webContents.send('window-visibility', { visible: true });
      if (!bubblePinned) {
        bubbleFocusedSinceShown = true;
        startBubbleOutsideWatch();
        startMacGlobalClickMonitorIfNeeded();
      }
    }
    return;
  }

  if (typeof mainWindow.showInactive === 'function') {
    mainWindow.showInactive();
    mainWindowShownAt = Date.now();
    if (bubbleMode) {
      mainWindow.webContents.send('window-visibility', { visible: true });
      if (!bubblePinned) {
        bubbleFocusedSinceShown = true;
        startBubbleOutsideWatch();
        startMacGlobalClickMonitorIfNeeded();
      }
    }
    return;
  }

  mainWindow.show();
  mainWindowShownAt = Date.now();
  if (bubbleMode) {
    mainWindow.webContents.send('window-visibility', { visible: true });
    if (!bubblePinned) {
      bubbleFocusedSinceShown = true;
      startBubbleOutsideWatch();
      startMacGlobalClickMonitorIfNeeded();
    }
  }
}

function showNotification(title, body) {
  if (Notification.isSupported()) {
    new Notification({ title, body }).show();
  }
}

function createMainWindow() {
  const preset = getTranslatorWindowPreset(runtimeConfig?.popupMode || 'panel');
  const popupMode = runtimeConfig?.popupMode || 'panel';
  const bubbleWindowMode = popupMode === 'bubble';

  mainWindow = new BrowserWindow({
    width: preset.defaultWidth,
    height: preset.defaultHeight,
    minWidth: preset.minWidth,
    minHeight: preset.minHeight,
    show: false,
    title: `${APP_NAME} 翻译`,
    frame: !bubbleWindowMode,
    transparent: bubbleWindowMode,
    hasShadow: true,
    resizable: !bubbleWindowMode,
    roundedCorners: true,
    autoHideMenuBar: true,
    backgroundColor: bubbleWindowMode ? '#00000000' : '#0f131a',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js')
    }
  });

  mainWindowPopupMode = popupMode;
  isMainWindowReady = false;
  if (process.platform === 'darwin') {
    try {
      mainWindow.setVisibleOnAllWorkspaces(bubbleWindowMode, { visibleOnFullScreen: true });
    } catch {
      // Ignore workspace visibility incompatibility on older macOS builds.
    }
  }
  mainWindow.loadFile(path.join(__dirname, 'renderer.html'));

  mainWindow.on('blur', () => {
    if (mainWindow && !mainWindow.isDestroyed() && mainWindow.isVisible()) {
      if (isBubbleMode()) {
        if (bubblePinned) {
          bubbleDismissedByBlur = false;
          mainWindow.webContents.send('window-visibility', { visible: true, pinned: true });
          return;
        }
        if (selectionReadInProgress) {
          return;
        }
        if (Date.now() - mainWindowShownAt < 260) {
          return;
        }
        hideBubbleWindow({ markDismissed: true });
        return;
      }
      stopBubbleOutsideWatch();
      mainWindow.hide();
    }
  });

  mainWindow.on('focus', () => {
    let clearedBubbleHideTimer = false;
    if (bubbleHideTimer) {
      const cursorPoint = screen.getCursorScreenPoint();
      const bounds = mainWindow && !mainWindow.isDestroyed() ? mainWindow.getBounds() : null;
      const pointerInsideWindow = isPointInsideBounds(cursorPoint, bounds);
      if (bubblePinned || pointerInsideWindow) {
        clearTimeout(bubbleHideTimer);
        bubbleHideTimer = null;
        clearedBubbleHideTimer = true;
      }
    }
    if (isBubbleMode()) {
      bubbleFocusedSinceShown = true;
      if (!bubbleHideTimer || clearedBubbleHideTimer || bubblePinned) {
        bubbleDismissedByBlur = false;
      }
      mainWindow.webContents.send('window-visibility', { visible: true });
      if (!bubblePinned) {
        startBubbleOutsideWatch();
      }
    }
  });

  mainWindow.on('hide', () => {
    bubbleFocusedSinceShown = false;
    stopBubbleOutsideWatch();
    stopMacGlobalClickMonitor();
  });

  mainWindow.on('closed', () => {
    isMainWindowReady = false;
    mainWindowPopupMode = null;
    if (bubbleHideTimer) {
      clearTimeout(bubbleHideTimer);
      bubbleHideTimer = null;
    }
    stopBubbleOutsideWatch();
    stopMacGlobalClickMonitor();
    mainWindow = null;
  });

  mainWindow.webContents.on('did-finish-load', () => {
    isMainWindowReady = true;
    emitShortcutsToRenderer();
    emitUiConfigToRenderer();
    emitAutomationConfigToRenderer();
    emitBubblePinStateToRenderer();
    flushPendingTranslationPayload();
  });
}

function clampToRange(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function isPointInsideBounds(point, bounds) {
  if (!point || !bounds) {
    return false;
  }

  return (
    point.x >= bounds.x &&
    point.x <= bounds.x + bounds.width &&
    point.y >= bounds.y &&
    point.y <= bounds.y + bounds.height
  );
}

function normalizeSelectionAnchor(anchor) {
  if (!anchor || typeof anchor !== 'object') {
    return null;
  }

  const x = Number(anchor.x);
  const y = Number(anchor.y);
  const width = Number(anchor.width);
  const height = Number(anchor.height);
  if (![x, y, width, height].every(Number.isFinite)) {
    return null;
  }

  return {
    x: Math.round(x),
    y: Math.round(y),
    width: Math.max(1, Math.round(width)),
    height: Math.max(1, Math.round(height))
  };
}

function placeTranslatorWindowOnActiveDisplay(options = {}) {
  if (!mainWindow || mainWindow.isDestroyed()) {
    return;
  }

  const popupMode = runtimeConfig?.popupMode || 'panel';
  if (
    popupMode === 'bubble' &&
    bubblePinned &&
    mainWindow.isVisible() &&
    options?.force !== true
  ) {
    return;
  }
  const preset = getTranslatorWindowPreset(popupMode);
  const anchor = normalizeSelectionAnchor(options?.anchor);
  const cursorPoint = screen.getCursorScreenPoint();
  const anchorCenter = anchor
    ? {
        x: Math.round(anchor.x + anchor.width / 2),
        y: Math.round(anchor.y + anchor.height / 2)
      }
    : null;
  const targetPoint = popupMode === 'bubble' && anchorCenter ? anchorCenter : cursorPoint;
  const targetDisplay = screen.getDisplayNearestPoint(targetPoint);
  const workArea = targetDisplay.workArea;
  const bounds = mainWindow.getBounds();
  const maxAllowedWidth = Math.max(420, workArea.width - POPUP_MARGIN * 2);
  const maxAllowedHeight = Math.max(340, workArea.height - POPUP_MARGIN * 2);

  const baseWidth = popupMode === 'bubble' ? preset.defaultWidth : bounds.width || preset.defaultWidth;
  const baseHeight =
    popupMode === 'bubble' ? preset.defaultHeight : bounds.height || preset.defaultHeight;

  const width = clampToRange(
    baseWidth,
    Math.min(preset.minWidth, maxAllowedWidth),
    maxAllowedWidth
  );
  const height = clampToRange(
    baseHeight,
    Math.min(preset.minHeight, maxAllowedHeight),
    maxAllowedHeight
  );

  let nextX = 0;
  let nextY = 0;

  if (popupMode === 'bubble' && anchor) {
    const anchorLeft = anchor.x;
    const anchorTop = anchor.y;
    const anchorRight = anchor.x + anchor.width;
    const anchorBottom = anchor.y + anchor.height;
    const sideOffset = 14;
    const verticalOffset = 8;

    nextX = anchorRight + sideOffset;
    if (nextX + width > workArea.x + workArea.width - POPUP_MARGIN) {
      nextX = anchorLeft - width - sideOffset;
    }

    nextY = anchorBottom + verticalOffset;
    if (nextY + height > workArea.y + workArea.height - POPUP_MARGIN) {
      nextY = anchorTop - height - verticalOffset;
    }
  } else {
    const edgeOffset = popupMode === 'bubble' ? 12 : POPUP_MARGIN;
    nextX = cursorPoint.x + edgeOffset;
    nextY = cursorPoint.y + edgeOffset;

    if (nextX + width > workArea.x + workArea.width - POPUP_MARGIN) {
      nextX = cursorPoint.x - width - edgeOffset;
    }

    if (nextY + height > workArea.y + workArea.height - POPUP_MARGIN) {
      nextY = cursorPoint.y - height - edgeOffset;
    }
  }

  const minX = workArea.x + POPUP_MARGIN;
  const maxX = workArea.x + workArea.width - width - POPUP_MARGIN;
  const minY = workArea.y + POPUP_MARGIN;
  const maxY = workArea.y + workArea.height - height - POPUP_MARGIN;

  nextX = clampToRange(nextX, minX, Math.max(minX, maxX));
  nextY = clampToRange(nextY, minY, Math.max(minY, maxY));

  mainWindow.setBounds(
    {
      x: Math.round(nextX),
      y: Math.round(nextY),
      width,
      height
    },
    false
  );
}

function applyTranslatorWindowMode() {
  if (!mainWindow || mainWindow.isDestroyed()) {
    return;
  }

  const popupMode = runtimeConfig?.popupMode || 'panel';
  const bubbleWindowMode = popupMode === 'bubble';
  const preset = getTranslatorWindowPreset(popupMode);
  const currentBounds = mainWindow.getBounds();
  const nextWidth =
    bubbleWindowMode
      ? preset.defaultWidth
      : Math.max(currentBounds.width, preset.minWidth);
  const nextHeight =
    bubbleWindowMode
      ? preset.defaultHeight
      : Math.max(currentBounds.height, preset.minHeight);

  mainWindow.setResizable(!bubbleWindowMode);
  mainWindow.setMinimumSize(preset.minWidth, preset.minHeight);
  mainWindow.setAlwaysOnTop(bubbleWindowMode, 'screen-saver');
  if (process.platform === 'darwin') {
    try {
      mainWindow.setVisibleOnAllWorkspaces(bubbleWindowMode, { visibleOnFullScreen: true });
    } catch {
      // Ignore workspace visibility incompatibility on older macOS builds.
    }
  }
  mainWindow.setBounds(
    {
      ...currentBounds,
      width: nextWidth,
      height: nextHeight
    },
    false
  );
}

function autoResizeTranslatorWindow(payload = {}) {
  if (!mainWindow || mainWindow.isDestroyed()) {
    return;
  }

  const popupMode = runtimeConfig?.popupMode || 'panel';
  if (popupMode === 'bubble' && Date.now() - mainWindowShownAt < 110) {
    return;
  }
  if (payload?.popupMode && payload.popupMode !== popupMode) {
    return;
  }

  const bounds = mainWindow.getBounds();
  const preset = getTranslatorWindowPreset(popupMode);
  const centerPoint = {
    x: Math.round(bounds.x + bounds.width / 2),
    y: Math.round(bounds.y + bounds.height / 2)
  };
  const display = screen.getDisplayNearestPoint(centerPoint);
  const workArea = display.workArea;
  const maxAllowedWidth = Math.max(420, workArea.width - POPUP_MARGIN * 2);
  const maxAllowedHeight = Math.max(340, workArea.height - POPUP_MARGIN * 2);
  const minAllowedWidth = Math.min(preset.minWidth, maxAllowedWidth);
  const minAllowedHeight = Math.min(preset.minHeight, maxAllowedHeight);
  const bubbleWindowMode = popupMode === 'bubble';
  const allowShrink = payload?.allowShrink === true;

  const rawHeight = Number(payload?.height);
  const fixedWidth = bubbleWindowMode
    ? clampToRange(preset.defaultWidth, minAllowedWidth, maxAllowedWidth)
    : clampToRange(bounds.width, minAllowedWidth, maxAllowedWidth);
  const targetHeight = clampToRange(
    Number.isFinite(rawHeight) ? Math.round(rawHeight) : bounds.height,
    minAllowedHeight,
    maxAllowedHeight
  );

  const heightGrowThreshold = bubbleWindowMode ? 3 : 8;
  const heightShrinkThreshold = bubbleWindowMode ? 14 : 18;
  const heightShouldGrow = targetHeight > bounds.height + heightGrowThreshold;
  const heightShouldShrink = allowShrink && targetHeight < bounds.height - heightShrinkThreshold;
  let nextHeight = bounds.height;
  if (heightShouldGrow) {
    nextHeight = targetHeight;
  } else if (heightShouldShrink) {
    nextHeight = targetHeight;
  }

  if (fixedWidth === bounds.width && nextHeight === bounds.height) {
    return;
  }

  let nextX = bounds.x;
  let nextY = bounds.y;

  if (nextX + fixedWidth > workArea.x + workArea.width - POPUP_MARGIN) {
    nextX = workArea.x + workArea.width - fixedWidth - POPUP_MARGIN;
  }
  if (nextY + nextHeight > workArea.y + workArea.height - POPUP_MARGIN) {
    nextY = workArea.y + workArea.height - nextHeight - POPUP_MARGIN;
  }

  const minX = workArea.x + POPUP_MARGIN;
  const maxX = workArea.x + workArea.width - fixedWidth - POPUP_MARGIN;
  const minY = workArea.y + POPUP_MARGIN;
  const maxY = workArea.y + workArea.height - nextHeight - POPUP_MARGIN;

  nextX = clampToRange(nextX, minX, Math.max(minX, maxX));
  nextY = clampToRange(nextY, minY, Math.max(minY, maxY));

  mainWindow.setBounds(
    {
      x: Math.round(nextX),
      y: Math.round(nextY),
      width: Math.round(fixedWidth),
      height: Math.round(nextHeight)
    },
    false
  );
}

function placePreferencesWindowOnActiveDisplay() {
  if (!preferencesWindow || preferencesWindow.isDestroyed()) {
    return;
  }

  const cursorPoint = screen.getCursorScreenPoint();
  const targetDisplay = screen.getDisplayNearestPoint(cursorPoint);
  const workArea = targetDisplay.workArea;
  const bounds = preferencesWindow.getBounds();
  const width = Math.min(bounds.width, workArea.width - POPUP_MARGIN * 2);
  const height = Math.min(bounds.height, workArea.height - POPUP_MARGIN * 2);

  const centeredX = workArea.x + Math.floor((workArea.width - width) / 2);
  const centeredY = workArea.y + Math.floor((workArea.height - height) / 2);
  const minX = workArea.x + POPUP_MARGIN;
  const maxX = workArea.x + workArea.width - width - POPUP_MARGIN;
  const minY = workArea.y + POPUP_MARGIN;
  const maxY = workArea.y + workArea.height - height - POPUP_MARGIN;

  preferencesWindow.setBounds(
    {
      x: clampToRange(centeredX, minX, Math.max(minX, maxX)),
      y: clampToRange(centeredY, minY, Math.max(minY, maxY)),
      width,
      height
    },
    false
  );
}

function createPreferencesWindow() {
  preferencesWindow = new BrowserWindow({
    width: 940,
    height: 650,
    minWidth: 860,
    minHeight: 580,
    show: false,
    title: `${APP_NAME} 偏好设置`,
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preferences-preload.js')
    }
  });

  preferencesWindow.loadFile(path.join(__dirname, 'preferences.html'));

  preferencesWindow.on('close', (event) => {
    if (!isQuitting) {
      event.preventDefault();
      preferencesWindow.hide();
    }
  });
}

function openPreferencesWindow() {
  if (!preferencesWindow || preferencesWindow.isDestroyed()) {
    createPreferencesWindow();
  }

  placePreferencesWindowOnActiveDisplay();
  preferencesWindow.show();
  preferencesWindow.focus();
}

function openRawSettingsFile() {
  shell.openPath(getSettingsPath());
}

function emitShortcutsToRenderer() {
  if (!mainWindow || mainWindow.isDestroyed()) {
    return;
  }

  mainWindow.webContents.send('shortcuts-updated', {
    translateShortcut: currentTranslateShortcut(),
    openSettingsShortcut: currentOpenSettingsShortcut()
  });
}

function emitUiConfigToRenderer() {
  if (!mainWindow || mainWindow.isDestroyed()) {
    return;
  }

  mainWindow.webContents.send('ui-config-updated', {
    popupMode: runtimeConfig?.popupMode || 'panel',
    fontSize: runtimeConfig?.fontSize || 16
  });
}

function emitAutomationConfigToRenderer() {
  if (!mainWindow || mainWindow.isDestroyed()) {
    return;
  }

  mainWindow.webContents.send('automation-config-updated', getAutomationConfig());
}

function flushPendingTranslationPayload() {
  if (!pendingTranslationPayload || !isMainWindowReady) {
    return;
  }
  if (!mainWindow || mainWindow.isDestroyed()) {
    return;
  }

  mainWindow.webContents.send('translation-result', pendingTranslationPayload);
  pendingTranslationPayload = null;
}

function sendTranslationResult(payload) {
  if (!mainWindow || mainWindow.isDestroyed()) {
    pendingTranslationPayload = payload;
    return;
  }

  if (!isMainWindowReady) {
    pendingTranslationPayload = payload;
    return;
  }

  mainWindow.webContents.send('translation-result', payload);
}

function isLikelyValidAccelerator(accelerator) {
  if (!accelerator) {
    return true;
  }

  const parts = String(accelerator)
    .split('+')
    .map((part) => part.trim())
    .filter(Boolean);

  if (parts.length < 2) {
    return false;
  }

  const key = parts[parts.length - 1];
  const modifiers = parts.slice(0, -1);
  const uniqueModifiers = new Set();

  for (const modifier of modifiers) {
    const normalized = modifier.toLowerCase();
    if (!MODIFIER_TOKENS.has(normalized)) {
      return false;
    }
    uniqueModifiers.add(normalized);
  }

  if (uniqueModifiers.size !== modifiers.length) {
    return false;
  }

  if (/^(commandorcontrol|command|cmd|control|ctrl|alt|option|shift|super)$/i.test(key)) {
    return false;
  }

  if (/^[A-Z0-9]$/i.test(key)) {
    return true;
  }

  if (/^F\d{1,2}$/i.test(key)) {
    return true;
  }

  return /^(Space|Tab|Enter|Esc|Backspace|Delete|Insert|Home|End|PageUp|PageDown|Up|Down|Left|Right|num[0-9]|numadd|numsub|nummult|numdiv|numdec)$/i.test(
    key
  );
}

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function backupClipboardData() {
  return {
    text: clipboard.readText() || ''
  };
}

function restoreClipboardData(snapshot) {
  const text = typeof snapshot?.text === 'string' ? snapshot.text : '';
  clipboard.writeText(text);
}

async function triggerSystemCopyShortcut() {
  if (process.platform === 'darwin') {
    const scriptCandidates = [
      'tell application "System Events" to key code 8 using command down',
      'tell application "System Events" to keystroke "c" using command down'
    ];
    let lastError = null;

    for (const script of scriptCandidates) {
      try {
        await execFileAsync(
          'osascript',
          ['-e', script],
          {
            timeout: AUTO_COPY_COMMAND_TIMEOUT_MS
          }
        );
        return true;
      } catch (error) {
        lastError = error;
      }
    }

    let helperError = null;
    try {
      const helperPath = macCopyHelperPath;
      if (helperPath) {
        await execFileAsync(
          helperPath,
          [],
          {
            timeout: AUTO_COPY_COMMAND_TIMEOUT_MS
          }
        );
        return true;
      }
    } catch (error) {
      helperError = error;
      const helperMessage = collectProcessErrorText(error);
      if (helperMessage.includes('accessibility_denied') || helperMessage.includes('ax_not_trusted')) {
        macCopyHelperPath = null;
        macCopyHelperRetryAfter = Date.now() + MAC_HELPER_PERMISSION_RETRY_COOLDOWN_MS;
      }
    }

    throw lastError || helperError || new Error('failed to trigger system copy shortcut');
  }

  if (process.platform === 'linux') {
    await execFileAsync(
      'xdotool',
      ['key', '--clearmodifiers', 'ctrl+c'],
      {
        timeout: AUTO_COPY_COMMAND_TIMEOUT_MS
      }
    );
    return true;
  }

  return false;
}

function getAutoCopyErrorMessage() {
  if (process.platform === 'darwin') {
    return '自动读取选中文本失败：请在“系统设置-隐私与安全性”中同时允许 Electron（或启动终端）的“辅助功能”和“自动化（控制 System Events）”。';
  }

  if (process.platform === 'linux') {
    return '自动读取选中文本失败：请安装 xdotool，或先复制后再翻译。';
  }

  return '当前系统不支持自动读取选中文本，请先复制后再翻译。';
}

function looksLikeAccessibilityError(error) {
  const message = collectProcessErrorText(error);
  return (
    message.includes('accessibility_denied') ||
    message.includes('ax_not_trusted') ||
    message.includes('not authorized') ||
    message.includes('not permitted') ||
    message.includes('operation not permitted') ||
    message.includes('1743') ||
    message.includes('10827') ||
    message.includes('system events got an error')
  );
}

function looksLikeTimeoutError(error) {
  const message = collectProcessErrorText(error);
  const code = String(error?.code || '').toLowerCase();
  const signal = String(error?.signal || '').toLowerCase();
  return (
    Boolean(error?.killed) ||
    code === 'etimedout' ||
    signal === 'sigterm' ||
    message.includes('timed out') ||
    message.includes('timeout')
  );
}

function createClipboardMarker() {
  return `__mini_bob_selection_marker_${Date.now()}_${Math.random().toString(36).slice(2)}__`;
}

function collectProcessErrorText(error) {
  return [error?.message, error?.stderr, error?.stdout]
    .filter(Boolean)
    .join('\n')
    .toLowerCase();
}

function parseMacSelectionHelperOutput(stdout) {
  const rawText = String(stdout || '').trim();
  if (!rawText) {
    return {
      text: '',
      anchor: null
    };
  }

  try {
    const parsed = JSON.parse(rawText);
    if (parsed && typeof parsed === 'object') {
      const text = String(parsed.text || '').trim();
      return {
        text,
        anchor: normalizeSelectionAnchor(parsed.anchor)
      };
    }
  } catch {
    // Fallback to the legacy plain-text output format.
  }

  return {
    text: rawText,
    anchor: null
  };
}

async function ensureMacSelectionHelperBuilt() {
  if (process.platform !== 'darwin') {
    return null;
  }

  if (Date.now() < macSelectionHelperRetryAfter) {
    return null;
  }

  if (macSelectionHelperUnavailable) {
    return null;
  }

  if (macSelectionHelperPath) {
    return macSelectionHelperPath;
  }

  if (macSelectionHelperBuildPromise) {
    return macSelectionHelperBuildPromise;
  }

  macSelectionHelperBuildPromise = (async () => {
    const sourcePath = path.join(__dirname, 'mac-selection.swift');
    const binaryPath = path.join(app.getPath('userData'), 'bin', 'jikeyi-selection');

    try {
      const sourceStat = fs.statSync(sourcePath);
      let shouldBuild = true;

      try {
        const binaryStat = fs.statSync(binaryPath);
        shouldBuild = binaryStat.mtimeMs < sourceStat.mtimeMs;
      } catch {
        shouldBuild = true;
      }

      if (shouldBuild) {
        const moduleCachePath = path.join(app.getPath('temp'), 'jikeyi-swift-module-cache');
        fs.mkdirSync(moduleCachePath, { recursive: true });
        fs.mkdirSync(path.dirname(binaryPath), { recursive: true });
        await execFileAsync(
          'xcrun',
          ['swiftc', '-O', sourcePath, '-o', binaryPath],
          {
            timeout: MAC_SELECTION_HELPER_BUILD_TIMEOUT_MS,
            env: {
              ...process.env,
              SWIFT_MODULE_CACHE_PATH: moduleCachePath,
              CLANG_MODULE_CACHE_PATH: moduleCachePath
            }
          }
        );
      }

      macSelectionHelperPath = binaryPath;
      macSelectionHelperUnavailable = false;
      macSelectionHelperRetryAfter = 0;
      return binaryPath;
    } catch (error) {
      macSelectionHelperUnavailable = false;
      macSelectionHelperRetryAfter = Date.now() + MAC_SELECTION_HELPER_BUILD_RETRY_COOLDOWN_MS;
      console.warn(`${APP_NAME}: build mac selection helper failed:`, error?.message || error);
      return null;
    } finally {
      macSelectionHelperBuildPromise = null;
    }
  })();

  return macSelectionHelperBuildPromise;
}

async function ensureMacCopyHelperBuilt() {
  if (process.platform !== 'darwin') {
    return null;
  }

  if (Date.now() < macCopyHelperRetryAfter) {
    return null;
  }

  if (macCopyHelperUnavailable) {
    return null;
  }

  if (macCopyHelperPath) {
    return macCopyHelperPath;
  }

  if (macCopyHelperBuildPromise) {
    return macCopyHelperBuildPromise;
  }

  macCopyHelperBuildPromise = (async () => {
    const sourcePath = path.join(__dirname, 'mac-copy-trigger.swift');
    const binaryPath = path.join(app.getPath('userData'), 'bin', 'jikeyi-copy-trigger');

    try {
      const sourceStat = fs.statSync(sourcePath);
      let shouldBuild = true;

      try {
        const binaryStat = fs.statSync(binaryPath);
        shouldBuild = binaryStat.mtimeMs < sourceStat.mtimeMs;
      } catch {
        shouldBuild = true;
      }

      if (shouldBuild) {
        const moduleCachePath = path.join(app.getPath('temp'), 'jikeyi-swift-module-cache');
        fs.mkdirSync(moduleCachePath, { recursive: true });
        fs.mkdirSync(path.dirname(binaryPath), { recursive: true });
        await execFileAsync(
          'xcrun',
          ['swiftc', '-O', sourcePath, '-o', binaryPath],
          {
            timeout: MAC_COPY_HELPER_BUILD_TIMEOUT_MS,
            env: {
              ...process.env,
              SWIFT_MODULE_CACHE_PATH: moduleCachePath,
              CLANG_MODULE_CACHE_PATH: moduleCachePath
            }
          }
        );
      }

      macCopyHelperPath = binaryPath;
      macCopyHelperUnavailable = false;
      macCopyHelperRetryAfter = 0;
      return binaryPath;
    } catch (error) {
      macCopyHelperUnavailable = false;
      macCopyHelperRetryAfter = Date.now() + MAC_COPY_HELPER_BUILD_RETRY_COOLDOWN_MS;
      console.warn(`${APP_NAME}: build mac copy helper failed:`, error?.message || error);
      return null;
    } finally {
      macCopyHelperBuildPromise = null;
    }
  })();

  return macCopyHelperBuildPromise;
}

async function ensureMacClickMonitorHelperBuilt() {
  if (process.platform !== 'darwin') {
    return null;
  }

  if (macClickMonitorUnavailable) {
    return null;
  }

  if (macClickMonitorHelperPath) {
    return macClickMonitorHelperPath;
  }

  if (macClickMonitorBuildPromise) {
    return macClickMonitorBuildPromise;
  }

  macClickMonitorBuildPromise = (async () => {
    const sourcePath = path.join(__dirname, 'mac-click-monitor.swift');
    const binaryPath = path.join(app.getPath('userData'), 'bin', 'jikeyi-click-monitor');

    try {
      const sourceStat = fs.statSync(sourcePath);
      let shouldBuild = true;

      try {
        const binaryStat = fs.statSync(binaryPath);
        shouldBuild = binaryStat.mtimeMs < sourceStat.mtimeMs;
      } catch {
        shouldBuild = true;
      }

      if (shouldBuild) {
        const moduleCachePath = path.join(app.getPath('temp'), 'jikeyi-swift-module-cache');
        fs.mkdirSync(moduleCachePath, { recursive: true });
        fs.mkdirSync(path.dirname(binaryPath), { recursive: true });
        await execFileAsync(
          'xcrun',
          ['swiftc', '-O', sourcePath, '-o', binaryPath],
          {
            timeout: MAC_CLICK_MONITOR_BUILD_TIMEOUT_MS,
            env: {
              ...process.env,
              SWIFT_MODULE_CACHE_PATH: moduleCachePath,
              CLANG_MODULE_CACHE_PATH: moduleCachePath
            }
          }
        );
      }

      macClickMonitorHelperPath = binaryPath;
      macClickMonitorUnavailable = false;
      return binaryPath;
    } catch (error) {
      macClickMonitorUnavailable = true;
      console.warn(`${APP_NAME}: build mac click monitor failed:`, error?.message || error);
      return null;
    } finally {
      macClickMonitorBuildPromise = null;
    }
  })();

  return macClickMonitorBuildPromise;
}

async function tryReadSelectionByMacHelper() {
  if (process.platform !== 'darwin') {
    return null;
  }

  let helperPath = macSelectionHelperPath;
  if (!helperPath) {
    if (!macSelectionHelperBuildPromise && !macSelectionHelperUnavailable) {
      void ensureMacSelectionHelperBuilt();
    }
    return null;
  }

  try {
    const { stdout } = await execFileAsync(helperPath, [], {
      timeout: MAC_SELECTION_HELPER_READ_TIMEOUT_MS
    });
    const parsed = parseMacSelectionHelperOutput(stdout);
    const text = parsed.text;
    if (!text) {
      return {
        text: '',
        source: 'selection-empty',
        anchor: parsed.anchor
      };
    }

    return {
      text,
      source: 'ax-helper',
      anchor: parsed.anchor
    };
  } catch (error) {
    const message = collectProcessErrorText(error);
    if (message.includes('accessibility_denied') || message.includes('ax_not_trusted')) {
      macSelectionHelperPath = null;
      macSelectionHelperRetryAfter = Date.now() + MAC_HELPER_PERMISSION_RETRY_COOLDOWN_MS;
      return {
        text: '',
        source: 'accessibility-permission'
      };
    }

    if (message.includes('no_selection') || message.includes('no_focused_element')) {
      return {
        text: '',
        source: 'selection-empty'
      };
    }

    return null;
  }
}

function getSelectionReadErrorMessage(source) {
  if (source === 'accessibility-permission') {
    return getAutoCopyErrorMessage();
  }

  if (source === 'auto-copy-failed') {
    return '自动复制触发失败：请先手动按 Cmd+C 后再触发翻译；若持续失败，再检查“辅助功能/自动化”权限。';
  }

  if (source === 'auto-copy-timeout') {
    return '自动读取选区超时：目标应用响应较慢。请重试，或先手动按 Cmd+C 后再触发翻译。';
  }

  if (source === 'selection-empty') {
    return '未读取到选中文本：请确认目标应用中可复制（先试一次 Cmd+C），再触发翻译。';
  }

  if (source === 'unsupported-platform') {
    return '当前系统不支持自动读取选中文本，请先复制后再翻译。';
  }

  return '未读取到选中文本，请先选中文本后再触发翻译。';
}

function getRoutingConfig() {
  return {
    autoRouteEnabled: runtimeConfig?.routing?.autoRouteEnabled !== false
  };
}

function getRuntimeGlossary() {
  return Array.isArray(runtimeConfig?.glossary) ? runtimeConfig.glossary : [];
}

function getAutomationConfig() {
  const automation = runtimeConfig?.automation || {};
  return {
    replaceLineBreaksWithSpace: automation.replaceLineBreaksWithSpace === true,
    stripCodeCommentMarkers: automation.stripCodeCommentMarkers === true,
    removeHyphenSpace: automation.removeHyphenSpace === true,
    autoCopyOcrResult: automation.autoCopyOcrResult === true,
    autoCopyFirstResult: automation.autoCopyFirstResult === true,
    copyHighlightedWordOnClick: automation.copyHighlightedWordOnClick === true,
    autoPlaySourceText: automation.autoPlaySourceText === true
  };
}

function preprocessSourceText(text, automation) {
  let output = String(text || '');
  if (!output) {
    return '';
  }

  const options = automation || getAutomationConfig();
  let shouldCompactWhitespace = false;

  if (options.stripCodeCommentMarkers) {
    output = output
      .replace(/\/\*+/g, ' ')
      .replace(/\*+\//g, ' ')
      .replace(/(^|\n)\s*\/\/+/g, '$1')
      .replace(/(^|\n)\s*#+/g, '$1');
    shouldCompactWhitespace = true;
  }

  if (options.replaceLineBreaksWithSpace) {
    output = output.replace(
      /([A-Za-z])-[ \t\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]*[\r\n\u000b\u000c\u0085\u2028\u2029]+[ \t\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]*([A-Za-z])/g,
      '$1$2'
    );
    output = output.replace(/[\s\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+/g, ' ');
    output = output.replace(/[\u200b\u200c\u200d\ufeff]/g, '');
    output = output.replace(/\u00ad+/g, '');
    shouldCompactWhitespace = true;
  }

  if (options.removeHyphenSpace) {
    output = output.replace(/([A-Za-z])-\s+([A-Za-z])/g, '$1$2');
    shouldCompactWhitespace = true;
  }

  if (shouldCompactWhitespace) {
    output = output.replace(/[ \t\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+/g, ' ');
  }

  return output.trim();
}

function getRuntimeTranslationServices() {
  const services = Array.isArray(runtimeConfig?.services) ? runtimeConfig.services : [];
  const normalized = services
    .filter((service) => service && typeof service === 'object')
    .map((service) => {
      const timeoutValue = Number(service.timeoutMs);
      return {
        id: String(service.id || '').trim() || `svc_${Math.random().toString(36).slice(2, 8)}`,
        name: String(service.name || '').trim() || '未命名服务',
        enabled: service.enabled !== false,
        baseUrl: String(service.baseUrl || '').trim(),
        apiKey: String(service.apiKey || '').trim(),
        model: String(service.model || '').trim(),
        targetLanguage: String(service.targetLanguage || runtimeConfig?.targetLanguage || '简体中文').trim(),
        timeoutMs:
          Number.isFinite(timeoutValue) && timeoutValue > 0
            ? Math.floor(timeoutValue)
            : runtimeConfig?.timeoutMs || 60000
      };
    })
    .filter((service) => service.baseUrl && service.model);

  if (normalized.length > 0) {
    return normalized;
  }

  return [
    {
      id: String(runtimeConfig?.activeServiceId || 'svc_runtime'),
      name: String(runtimeConfig?.activeServiceName || '当前服务'),
      enabled: true,
      baseUrl: String(runtimeConfig?.baseUrl || '').trim(),
      apiKey: String(runtimeConfig?.apiKey || '').trim(),
      model: String(runtimeConfig?.model || '').trim(),
      targetLanguage: String(runtimeConfig?.targetLanguage || '简体中文').trim(),
      timeoutMs: runtimeConfig?.timeoutMs || 60000
    }
  ].filter((service) => service.baseUrl && service.model);
}

function ensureServiceRoutingMetric(serviceId) {
  const key = String(serviceId || '').trim() || '__unknown_service__';
  if (!serviceRoutingMetrics.has(key)) {
    serviceRoutingMetrics.set(key, {
      attempts: 0,
      successes: 0,
      failures: 0,
      timeouts: 0,
      consecutiveFailures: 0,
      timeoutStreak: 0,
      ewmaLatencyMs: SERVICE_ROUTE_INITIAL_LATENCY_MS,
      lastLatencyMs: SERVICE_ROUTE_INITIAL_LATENCY_MS,
      lastError: '',
      updatedAt: 0
    });
  }
  return serviceRoutingMetrics.get(key);
}

function updateServiceMetricOnSuccess(service, latencyMs) {
  const metric = ensureServiceRoutingMetric(service?.id);
  const boundedLatency = Math.max(40, Math.round(latencyMs || SERVICE_ROUTE_INITIAL_LATENCY_MS));
  metric.attempts += 1;
  metric.successes += 1;
  metric.consecutiveFailures = 0;
  metric.timeoutStreak = 0;
  metric.lastError = '';
  metric.lastLatencyMs = boundedLatency;
  metric.ewmaLatencyMs =
    metric.ewmaLatencyMs * (1 - SERVICE_ROUTE_EWMA_ALPHA) +
    boundedLatency * SERVICE_ROUTE_EWMA_ALPHA;
  metric.updatedAt = Date.now();
}

function isTimeoutLikeError(error) {
  if (error?.isTimeout || error?.code === 'TIMEOUT') {
    return true;
  }

  const message = String(error?.message || '').toLowerCase();
  return (
    message.includes('timeout') ||
    message.includes('timed out') ||
    message.includes('aborted') ||
    message.includes('etimedout')
  );
}

function updateServiceMetricOnFailure(service, latencyMs, error) {
  const metric = ensureServiceRoutingMetric(service?.id);
  const boundedLatency = Math.max(40, Math.round(latencyMs || metric.ewmaLatencyMs));
  const timedOut = isTimeoutLikeError(error);
  metric.attempts += 1;
  metric.failures += 1;
  metric.consecutiveFailures += 1;
  metric.timeoutStreak = timedOut ? metric.timeoutStreak + 1 : 0;
  if (timedOut) {
    metric.timeouts += 1;
  }
  metric.lastLatencyMs = boundedLatency;
  metric.lastError = String(error?.message || error || 'unknown-error');
  metric.updatedAt = Date.now();
}

function scoreServiceForRouting(service) {
  const metric = ensureServiceRoutingMetric(service.id);
  const baseline = Number.isFinite(metric.ewmaLatencyMs)
    ? metric.ewmaLatencyMs
    : SERVICE_ROUTE_INITIAL_LATENCY_MS;
  const failureRate = metric.attempts > 0 ? metric.failures / metric.attempts : 0;

  let score = baseline;
  score += metric.consecutiveFailures * SERVICE_ROUTE_FAILURE_PENALTY_MS;
  score += metric.timeoutStreak * SERVICE_ROUTE_TIMEOUT_PENALTY_MS;
  score += failureRate * 540;
  if (service.enabled === false) {
    score += SERVICE_ROUTE_DISABLED_PENALTY_MS;
  }
  if (service.id === runtimeConfig?.activeServiceId) {
    score -= 36;
  }

  return score;
}

function rankServicesForCurrentRequest() {
  const services = getRuntimeTranslationServices();
  if (services.length === 0) {
    return [];
  }

  const routing = getRoutingConfig();
  const enabledServices = services.filter((service) => service.enabled !== false);
  const pool = enabledServices.length > 0 ? enabledServices : services;
  const active = getActiveService(pool, runtimeConfig?.activeServiceId) || pool[0];
  const rest = pool.filter((service) => service.id !== active.id);
  const rankedRest = routing.autoRouteEnabled
    ? [...rest].sort((a, b) => scoreServiceForRouting(a) - scoreServiceForRouting(b))
    : rest;
  return [active, ...rankedRest];
}

function pickServicesForCurrentPopupMode(services) {
  if (!Array.isArray(services) || services.length === 0) {
    return [];
  }

  if ((runtimeConfig?.popupMode || 'panel') !== 'bubble') {
    return services;
  }

  const configuredIds = Array.isArray(runtimeConfig?.bubbleVisibleServiceIds)
    ? runtimeConfig.bubbleVisibleServiceIds
        .map((item) => String(item || '').trim())
        .filter(Boolean)
    : [];

  if (configuredIds.length === 0) {
    return services;
  }

  const allowedIds = new Set(configuredIds);
  const filtered = services.filter((service) => allowedIds.has(service.id));
  if (filtered.length > 0) {
    return filtered;
  }

  const activeService = getActiveService(services, runtimeConfig?.activeServiceId);
  return activeService ? [activeService] : services.slice(0, 1);
}

function serviceLabel(service) {
  return String(service?.name || service?.id || '未命名服务');
}

async function pollClipboardUntilCopied(marker, waitMs) {
  const deadline = Date.now() + waitMs;
  while (Date.now() < deadline) {
    await sleep(AUTO_COPY_POLL_INTERVAL_MS);
    const copiedText = clipboard.readText()?.trim();
    if (copiedText && copiedText !== marker) {
      return copiedText;
    }
  }
  return '';
}

async function readSelectionText() {
  if (process.platform === 'linux') {
    const selectionText = clipboard.readText('selection')?.trim();
    if (selectionText) {
      return {
        text: selectionText,
        source: 'selection-buffer'
      };
    }
  }

  const readSelectionByAutoCopy = async () => {
    const fallbackClipboardText = clipboard.readText()?.trim() || '';
    const readManualClipboardFallback = (sourceTag) => {
      if (!fallbackClipboardText) {
        return null;
      }
      return {
        text: fallbackClipboardText,
        source: sourceTag
      };
    };

    if (process.platform === 'win32') {
      return {
        text: fallbackClipboardText,
        source: 'clipboard-fallback'
      };
    }

    const clipboardSnapshot = backupClipboardData();
    const marker = createClipboardMarker();
    clipboard.writeText(marker);

    try {
      let lastCopyError = null;

      for (let attempt = 0; attempt < AUTO_COPY_MAX_ATTEMPTS; attempt += 1) {
        const delay = attempt === 0 ? AUTO_COPY_TRIGGER_DELAY_MS : AUTO_COPY_RETRY_DELAY_MS;
        const waitMs = attempt === 0 ? AUTO_COPY_FIRST_WAIT_MS : AUTO_COPY_RETRY_WAIT_MS;
        await sleep(delay);

        try {
          const copiedBySystem = await triggerSystemCopyShortcut();
          if (!copiedBySystem) {
            return {
              text: '',
              source: 'unsupported-platform'
            };
          }

          const copiedText = await pollClipboardUntilCopied(marker, waitMs);
          if (copiedText) {
            const source = attempt === 0 ? 'auto-copy' : 'auto-copy-retry';
            return {
              text: copiedText,
              source
            };
          }
        } catch (error) {
          if (looksLikeAccessibilityError(error)) {
            const manualFallback = readManualClipboardFallback('clipboard-fallback-manual');
            if (manualFallback) {
              return manualFallback;
            }
            return {
              text: '',
              source: 'accessibility-permission'
            };
          }
          const copiedTextAfterError = await pollClipboardUntilCopied(marker, waitMs);
          if (copiedTextAfterError) {
            const source =
              attempt === 0 ? 'auto-copy-timeout-recovered' : 'auto-copy-retry-timeout-recovered';
            return {
              text: copiedTextAfterError,
              source
            };
          }
          lastCopyError = error;
        }
      }

      if (lastCopyError) {
        const manualFallback = readManualClipboardFallback('clipboard-fallback-error');
        if (manualFallback) {
          return manualFallback;
        }
        if (looksLikeTimeoutError(lastCopyError)) {
          return {
            text: '',
            source: 'auto-copy-timeout'
          };
        }
        if (looksLikeAccessibilityError(lastCopyError)) {
          return {
            text: '',
            source: 'accessibility-permission'
          };
        }
        return {
          text: '',
          source: 'auto-copy-failed'
        };
      }

      const manualFallback = readManualClipboardFallback('clipboard-fallback-empty');
      if (manualFallback) {
        return manualFallback;
      }

      return {
        text: '',
        source: 'selection-empty'
      };
    } catch {
      const manualFallback = readManualClipboardFallback('clipboard-fallback-exception');
      if (manualFallback) {
        return manualFallback;
      }
      return {
        text: '',
        source: 'auto-copy-failed'
      };
    } finally {
      restoreClipboardData(clipboardSnapshot);
    }
  };

  if (process.platform === 'darwin') {
    const nativeSelectionPromise = tryReadSelectionByMacHelper();
    const helperProbeTimeout = Symbol('mac-helper-probe-timeout');
    const helperProbeResult = await Promise.race([
      nativeSelectionPromise,
      sleep(MAC_SELECTION_HELPER_PROBE_WAIT_MS).then(() => helperProbeTimeout)
    ]);

    if (helperProbeResult !== helperProbeTimeout) {
      if (helperProbeResult?.text) {
        return helperProbeResult;
      }
      if (helperProbeResult?.source === 'accessibility-permission') {
        const fallbackResult = await readSelectionByAutoCopy();
        if (fallbackResult?.text) {
          return fallbackResult;
        }
        return fallbackResult || helperProbeResult;
      }
      return readSelectionByAutoCopy();
    }

    const autoCopyPromise = readSelectionByAutoCopy();
    const firstCompleted = await Promise.race([
      nativeSelectionPromise.then((result) => ({
        provider: 'helper',
        result
      })),
      autoCopyPromise.then((result) => ({
        provider: 'auto-copy',
        result
      }))
    ]);

    if (firstCompleted.provider === 'helper') {
      const helperResult = firstCompleted.result;
      if (helperResult?.text) {
        return helperResult;
      }
      if (helperResult?.source === 'accessibility-permission') {
        const fallbackResult = await autoCopyPromise;
        if (fallbackResult?.text) {
          return fallbackResult;
        }
        return fallbackResult || helperResult;
      }
      return autoCopyPromise;
    }

    const copyResult = firstCompleted.result;
    if (copyResult?.text) {
      return copyResult;
    }

    const helperResult = await nativeSelectionPromise;
    if (helperResult?.text) {
      return helperResult;
    }
    if (helperResult?.source === 'accessibility-permission') {
      return copyResult || helperResult;
    }
    const helperRetryResult = await tryReadSelectionByMacHelper();
    if (helperRetryResult?.text) {
      return helperRetryResult;
    }
    if (helperRetryResult?.source === 'accessibility-permission') {
      return copyResult || helperRetryResult;
    }
    return copyResult;
  }

  return readSelectionByAutoCopy();
}

async function translateFromSelection() {
  const sourceType = 'selection';
  const popupMode = runtimeConfig?.popupMode || 'panel';
  const bubbleMode = popupMode === 'bubble';
  if (translationInProgress) {
    openTranslatorWindow({ anchor: latestSelectionAnchor });
    sendTranslationResult({
      sourceText: '',
      translation: '',
      error: '已有翻译任务进行中，请稍候...',
      stage: 'busy',
      sourceType
    });
    return;
  }

  translationInProgress = true;
  selectionReadInProgress = true;
  bubbleDismissedByBlur = false;
  latestSelectionAnchor = null;
  let latestSourceTextForError = '';
  openTranslatorWindow({
    focus: false,
    anchor: latestSelectionAnchor
  });

  sendTranslationResult({
    sourceText: '',
    translation: '正在读取选中文本...',
    error: '',
    stage: 'reading',
    sourceType
  });

  try {
    const selectionResult = await readSelectionText();
    selectionReadInProgress = false;
    const sourceText = selectionResult.text;
    const selectionAnchor = normalizeSelectionAnchor(selectionResult.anchor);
    latestSelectionAnchor = selectionAnchor;
    if (!mainWindow || mainWindow.isDestroyed() || !mainWindow.isVisible()) {
      openTranslatorWindow({ focus: true, anchor: selectionAnchor });
    } else if (bubbleMode) {
      openTranslatorWindow({ focus: true, anchor: selectionAnchor });
    }

    if (!sourceText) {
      const errorMessage = getSelectionReadErrorMessage(selectionResult.source);

      showNotification(APP_NAME, errorMessage);
      sendTranslationResult({
        sourceText: '',
        translation: '',
        error: errorMessage,
        stage: 'error',
        sourceType
      });
      return;
    }

    const automation = getAutomationConfig();
    const translationSourceText = preprocessSourceText(sourceText, automation) || sourceText;
    latestSourceTextForError = translationSourceText;

    const rankedServices = rankServicesForCurrentRequest();
    const serviceCandidates = pickServicesForCurrentPopupMode(rankedServices);
    if (serviceCandidates.length === 0) {
      throw new Error('没有可用翻译服务，请先在偏好设置里配置服务。');
    }

    const glossary = getRuntimeGlossary();
    const serviceStates = serviceCandidates.map((service, index) => ({
      id: service.id,
      name: serviceLabel(service),
      model: String(service.model || '').trim(),
      order: index,
      status: 'pending',
      translation: '',
      error: ''
    }));
    const stateById = new Map(serviceStates.map((item) => [item.id, item]));
    const snapshotService = (item) => ({
      id: item.id,
      name: item.name,
      model: item.model,
      order: item.order,
      status: item.status,
      translation: item.translation,
      error: item.error
    });

    const buildSummary = () => {
      const summary = {
        total: serviceStates.length,
        pending: 0,
        running: 0,
        streaming: 0,
        done: 0,
        error: 0
      };
      for (const item of serviceStates) {
        if (item.status === 'pending') {
          summary.pending += 1;
          continue;
        }
        if (item.status === 'running') {
          summary.running += 1;
          continue;
        }
        if (item.status === 'streaming') {
          summary.streaming += 1;
          continue;
        }
        if (item.status === 'done') {
          summary.done += 1;
          continue;
        }
        if (item.status === 'error') {
          summary.error += 1;
        }
      }
      return summary;
    };

    const snapshotServices = () => serviceStates.map((item) => snapshotService(item));

    const emitServicesSnapshot = (stage, extra = {}) => {
      const changedServiceId = String(extra?.changedServiceId || '').trim();
      const changedState = changedServiceId ? stateById.get(changedServiceId) : null;
      const serviceDeltaMode = String(extra?.serviceDeltaMode || 'replace').trim() || 'replace';
      const {
        changedServiceId: _ignoreChangedServiceId,
        serviceDeltaMode: _ignoreServiceDeltaMode,
        serviceDeltaChunk: _ignoreServiceDeltaChunk,
        serviceDeltaLength: _ignoreServiceDeltaLength,
        ...publicExtra
      } = extra || {};
      const canUseDelta =
        stage === 'service-update' &&
        changedState &&
        isMainWindowReady &&
        mainWindow &&
        !mainWindow.isDestroyed();

      if (canUseDelta) {
        let serviceDeltaPayload = snapshotService(changedState);
        if (serviceDeltaMode === 'append') {
          serviceDeltaPayload = {
            id: changedState.id,
            status: changedState.status,
            error: changedState.error,
            translationDelta: String(extra?.serviceDeltaChunk || ''),
            translationLength: Number.isFinite(Number(extra?.serviceDeltaLength))
              ? Math.max(0, Math.floor(Number(extra.serviceDeltaLength)))
              : String(changedState.translation || '').length
          };
        }

        sendTranslationResult({
          translation: '',
          error: '',
          sourceType,
          stage,
          summary: buildSummary(),
          changedServiceId,
          serviceDeltaMode,
          serviceDelta: serviceDeltaPayload,
          ...publicExtra
        });
        return;
      }

      sendTranslationResult({
        sourceText: translationSourceText,
        translation: '',
        error: '',
        sourceType,
        stage,
        services: snapshotServices(),
        summary: buildSummary(),
        changedServiceId: changedServiceId || undefined,
        ...publicExtra
      });
    };

    emitServicesSnapshot('translating');

    const runServiceTranslation = async (service) => {
      const state = stateById.get(service.id);
      if (!state) {
        return {
          ok: false,
          error: new Error(`未知服务：${service.id}`)
        };
      }

      state.status = 'running';
      state.error = '';
      state.translation = '';
      emitServicesSnapshot('service-update', { changedServiceId: service.id });

      const startedAt = Date.now();
      let streamedOnce = false;
      let latestTranslation = '';
      let lastEmitAt = 0;
      let pendingDeltaChunk = '';
      let consumedFullTextLength = 0;

      const emitStreamUpdate = (force = false) => {
        const now = Date.now();
        if (!force && now - lastEmitAt < SERVICE_STREAM_UPDATE_THROTTLE_MS) {
          return;
        }
        lastEmitAt = now;

        if (!force && pendingDeltaChunk) {
          emitServicesSnapshot('service-update', {
            changedServiceId: service.id,
            serviceDeltaMode: 'append',
            serviceDeltaChunk: pendingDeltaChunk,
            serviceDeltaLength: latestTranslation.length
          });
          pendingDeltaChunk = '';
          return;
        }

        emitServicesSnapshot('service-update', {
          changedServiceId: service.id,
          serviceDeltaMode: 'replace'
        });
      };

      try {
        await streamTranslateText(
          translationSourceText,
          {
            onDelta: (fullText, deltaText) => {
              streamedOnce = true;
              latestTranslation = fullText;
              state.status = 'streaming';
              state.translation = fullText;
              state.error = '';

              let chunk = '';
              if (typeof deltaText === 'string' && deltaText.length > 0) {
                chunk = deltaText;
              } else if (fullText.length > consumedFullTextLength) {
                chunk = fullText.slice(consumedFullTextLength);
              }
              consumedFullTextLength = fullText.length;
              if (chunk) {
                pendingDeltaChunk += chunk;
              }
              emitStreamUpdate(false);
            }
          },
          {
            serviceConfig: service,
            glossary
          }
        );

        if (!latestTranslation.trim()) {
          throw new Error('流式返回为空');
        }

        updateServiceMetricOnSuccess(service, Date.now() - startedAt);
        state.status = 'done';
        state.translation = latestTranslation.trim();
        state.error = '';
        consumedFullTextLength = state.translation.length;
        pendingDeltaChunk = '';
        emitStreamUpdate(true);
        return {
          ok: true,
          serviceId: service.id,
          translation: state.translation
        };
      } catch (streamError) {
        if (streamedOnce) {
          updateServiceMetricOnFailure(service, Date.now() - startedAt, streamError);
          const message = streamError instanceof Error ? streamError.message : String(streamError);
          state.status = 'error';
          state.error = message;
          pendingDeltaChunk = '';
          emitStreamUpdate(true);
          return {
            ok: false,
            error: streamError
          };
        }

        try {
          const translation = await translateText(translationSourceText, {
            serviceConfig: service,
            glossary
          });

          updateServiceMetricOnSuccess(service, Date.now() - startedAt);
          state.status = 'done';
          state.translation = String(translation || '').trim();
          state.error = '';
          consumedFullTextLength = state.translation.length;
          pendingDeltaChunk = '';
          emitStreamUpdate(true);
          return {
            ok: true,
            serviceId: service.id,
            translation: state.translation
          };
        } catch (directError) {
          updateServiceMetricOnFailure(service, Date.now() - startedAt, directError);
          const message = directError instanceof Error ? directError.message : String(directError);
          state.status = 'error';
          state.error = message;
          pendingDeltaChunk = '';
          emitStreamUpdate(true);
          return {
            ok: false,
            error: directError
          };
        }
      }
    };

    const settledResults = await Promise.all(serviceCandidates.map((service) => runServiceTranslation(service)));
    const successResults = settledResults.filter((item) => item?.ok);
    const failedResult = settledResults.find((item) => !item?.ok);

    if (successResults.length === 0) {
      const firstError = failedResult?.error;
      const message =
        firstError instanceof Error
          ? firstError.message
          : '翻译失败：所有服务均未返回可用结果。';
      emitServicesSnapshot('all-done', { error: message });
      showNotification(APP_NAME, message);
      return;
    }

    emitServicesSnapshot('all-done');
  } catch (error) {
    selectionReadInProgress = false;
    const message = error instanceof Error ? error.message : String(error);
    openTranslatorWindow({ anchor: latestSelectionAnchor });
    sendTranslationResult({
      sourceText: latestSourceTextForError,
      translation: '',
      error: message,
      stage: 'error',
      sourceType
    });
    showNotification(APP_NAME, message);
  } finally {
    selectionReadInProgress = false;
    translationInProgress = false;
  }
}

function registerShortcut(primaryAccelerator, fallbackAccelerator, handler, name) {
  const tried = [];

  const tryRegister = (accelerator) => {
    if (!accelerator || tried.includes(accelerator)) {
      return false;
    }
    tried.push(accelerator);
    try {
      return globalShortcut.register(accelerator, handler);
    } catch {
      return false;
    }
  };

  if (tryRegister(primaryAccelerator)) {
    return primaryAccelerator;
  }

  if (tryRegister(fallbackAccelerator)) {
    showNotification(APP_NAME, `${name}快捷键已回退为：${fallbackAccelerator}`);
    return fallbackAccelerator;
  }

  showNotification(APP_NAME, `快捷键注册失败：${name}（尝试过 ${tried.join(' / ')}）`);
  return null;
}

function setupShortcuts() {
  shortcutRegistrationResult.translateShortcut = registerShortcut(
    runtimeConfig.translateShortcut,
    DEFAULT_SHORTCUTS.translateShortcut,
    () => {
      translateFromSelection();
    },
    '翻译'
  );

  shortcutRegistrationResult.openSettingsShortcut = registerShortcut(
    runtimeConfig.openSettingsShortcut,
    DEFAULT_SHORTCUTS.openSettingsShortcut,
    openPreferencesWindow,
    '偏好设置'
  );
}

function switchActiveService(serviceId) {
  const settings = readSettings();
  const services = Array.isArray(settings.services) ? settings.services : [];
  if (services.length === 0) {
    showNotification(APP_NAME, '当前没有可切换的服务，请先在偏好设置里新增服务。');
    return;
  }

  const requestedId = typeof serviceId === 'string' ? serviceId.trim() : '';
  const nextActiveService = getActiveService(services, requestedId);
  if (!nextActiveService) {
    showNotification(APP_NAME, '服务切换失败：未找到可用服务。');
    return;
  }

  if (settings.activeServiceId === nextActiveService.id) {
    return;
  }

  writeSettings({
    ...settings,
    activeServiceId: nextActiveService.id
  });
  loadRuntimeConfig();
  applyRuntimeConfig();
  showNotification(APP_NAME, `已切换服务：${nextActiveService.name}`);
}

function serviceSwitchMenuTemplate() {
  const settings = readSettings();
  const services = Array.isArray(settings.services) ? settings.services : [];
  const activeService = getActiveService(services, runtimeConfig?.activeServiceId || settings.activeServiceId);

  if (services.length === 0) {
    return [
      {
        label: '暂无服务',
        enabled: false
      }
    ];
  }

  return services.map((service) => {
    const name = service.name || service.id || '未命名服务';
    const label = service.enabled ? name : `${name}（停用）`;
    const isChecked = activeService ? service.id === activeService.id : false;

    return {
      label,
      type: 'radio',
      checked: isChecked,
      enabled: service.enabled || isChecked,
      click: () => {
        switchActiveService(service.id);
      }
    };
  });
}

function buildMenu() {
  const template = [
    {
      label: APP_NAME,
      submenu: [
        {
          label: '翻译当前选中文本',
          accelerator: shortcutRegistrationResult.translateShortcut || undefined,
          click: translateFromSelection
        },
        {
          label: '偏好设置',
          accelerator: shortcutRegistrationResult.openSettingsShortcut || undefined,
          click: openPreferencesWindow
        },
        {
          label: `切换服务（${runtimeConfig?.activeServiceName || '未设置'}）`,
          submenu: serviceSwitchMenuTemplate()
        },
        {
          label: '打开原始配置文件',
          click: openRawSettingsFile
        },
        {
          type: 'separator'
        },
        {
          label: '退出',
          role: 'quit'
        }
      ]
    }
  ];

  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function trayMenuTemplate() {
  const translateShortcut = currentTranslateShortcut();

  return [
    {
      label: translateShortcut
        ? `立即翻译选中文本（${translateShortcut}）`
        : '立即翻译选中文本',
      click: translateFromSelection
    },
    {
      label: '显示翻译窗口',
      click: openTranslatorWindow
    },
    {
      label: '偏好设置',
      click: openPreferencesWindow
    },
    {
      label: `切换服务（${runtimeConfig?.activeServiceName || '未设置'}）`,
      submenu: [
        ...serviceSwitchMenuTemplate(),
        {
          type: 'separator'
        },
        {
          label: '打开偏好设置管理服务',
          click: openPreferencesWindow
        }
      ]
    },
    {
      label: '打开原始配置文件',
      click: openRawSettingsFile
    },
    {
      type: 'separator'
    },
    {
      label: '退出',
      role: 'quit'
    }
  ];
}

function refreshTrayMenu() {
  if (!tray) {
    return;
  }

  tray.setContextMenu(Menu.buildFromTemplate(trayMenuTemplate()));
  tray.setToolTip(`${APP_NAME}（${currentTranslateShortcut()}）`);
}

function createTray() {
  tray = new Tray(createTrayIcon());
  if (process.platform === 'darwin') {
    tray.setTitle('译');
  }

  tray.setIgnoreDoubleClickEvents(true);
  tray.on('click', () => {
    tray?.popUpContextMenu();
  });
  tray.on('right-click', () => {
    tray?.popUpContextMenu();
  });
  refreshTrayMenu();
}

function applyRuntimeConfig() {
  if (!isBubbleMode()) {
    bubblePinned = false;
    bubbleDismissedByBlur = false;
    bubbleFocusedSinceShown = false;
    if (bubbleHideTimer) {
      clearTimeout(bubbleHideTimer);
      bubbleHideTimer = null;
    }
    stopBubbleOutsideWatch();
    stopMacGlobalClickMonitor();
  }

  globalShortcut.unregisterAll();
  setupShortcuts();
  ensureMainWindowForCurrentMode();
  applyTranslatorWindowMode();
  buildMenu();
  refreshTrayMenu();
  emitShortcutsToRenderer();
  emitUiConfigToRenderer();
  emitAutomationConfigToRenderer();
  emitBubblePinStateToRenderer();

  if (isBubbleMode()) {
    startMacGlobalClickMonitorIfNeeded();
  }
}

function normalizeTimeoutValue(value, fallback) {
  const raw = String(value ?? '').trim();
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return String(fallback);
  }
  return String(Math.floor(parsed));
}

function sanitizeServicePayload(rawService, index, envFallback) {
  const fallbackId = `svc_${index + 1}`;
  const fallbackName = `服务 ${index + 1}`;

  const id =
    typeof rawService?.id === 'string' && rawService.id.trim()
      ? rawService.id.trim()
      : fallbackId;

  const name =
    typeof rawService?.name === 'string' && rawService.name.trim()
      ? rawService.name.trim()
      : fallbackName;

  const baseUrl =
    typeof rawService?.baseUrl === 'string' && rawService.baseUrl.trim()
      ? rawService.baseUrl.trim()
      : String(envFallback.ANTHROPIC_BASE_URL || '').trim();

  const apiKey =
    typeof rawService?.apiKey === 'string'
      ? rawService.apiKey.trim()
      : String(envFallback.ANTHROPIC_AUTH_TOKEN || '').trim();

  const model =
    typeof rawService?.model === 'string' && rawService.model.trim()
      ? rawService.model.trim()
      : String(envFallback.ANTHROPIC_MODEL || '').trim();

  const targetLanguage =
    typeof rawService?.targetLanguage === 'string' && rawService.targetLanguage.trim()
      ? rawService.targetLanguage.trim()
      : String(envFallback.TARGET_LANGUAGE || '简体中文').trim();

  const timeoutMs = normalizeTimeoutValue(
    rawService?.timeoutMs,
    envFallback.API_TIMEOUT_MS || '60000'
  );

  return {
    id,
    name,
    enabled: rawService?.enabled !== false,
    baseUrl,
    apiKey,
    model,
    targetLanguage,
    timeoutMs
  };
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

function normalizeRoutingPayload(rawRouting, fallback = DEFAULT_SETTINGS.routing) {
  const base = fallback && typeof fallback === 'object' ? fallback : DEFAULT_SETTINGS.routing;
  const source = rawRouting && typeof rawRouting === 'object' ? rawRouting : {};

  return {
    autoRouteEnabled: coerceBoolean(source.autoRouteEnabled, base.autoRouteEnabled !== false),
    fallbackEnabled: coerceBoolean(source.fallbackEnabled, base.fallbackEnabled !== false)
  };
}

function normalizeServiceIdListPayload(rawIds, services, fallbackIds = []) {
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

  const fallback = Array.isArray(fallbackIds)
    ? fallbackIds.map((item) => String(item || '').trim()).filter(Boolean)
    : [];
  if (fallback.length > 0) {
    return fallback;
  }

  return sourceServices
    .map((service) => String(service?.id || '').trim())
    .filter(Boolean);
}

function normalizeGlossaryPayload(rawGlossary) {
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

function normalizeAutomationPayload(rawAutomation, fallback = DEFAULT_SETTINGS.automation) {
  const base =
    fallback && typeof fallback === 'object' ? fallback : DEFAULT_SETTINGS.automation;
  const source = rawAutomation && typeof rawAutomation === 'object' ? rawAutomation : {};

  return {
    replaceLineBreaksWithSpace: coerceBoolean(
      source.replaceLineBreaksWithSpace,
      base.replaceLineBreaksWithSpace === true
    ),
    stripCodeCommentMarkers: coerceBoolean(
      source.stripCodeCommentMarkers,
      base.stripCodeCommentMarkers === true
    ),
    removeHyphenSpace: coerceBoolean(
      source.removeHyphenSpace,
      base.removeHyphenSpace === true
    ),
    autoCopyOcrResult: coerceBoolean(source.autoCopyOcrResult, base.autoCopyOcrResult === true),
    autoCopyFirstResult: coerceBoolean(
      source.autoCopyFirstResult,
      base.autoCopyFirstResult === true
    ),
    copyHighlightedWordOnClick: coerceBoolean(
      source.copyHighlightedWordOnClick,
      base.copyHighlightedWordOnClick === true
    ),
    autoPlaySourceText: coerceBoolean(source.autoPlaySourceText, base.autoPlaySourceText === true)
  };
}

function dedupeServiceIds(services) {
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

function toPreferencesResponse() {
  const settings = readSettings();
  const env = settings.env || {};
  const services = Array.isArray(settings.services) ? settings.services : [];
  const activeService = getActiveService(services, settings.activeServiceId);
  const routing = normalizeRoutingPayload(settings.routing, DEFAULT_SETTINGS.routing);
  const bubbleVisibleServiceIds = normalizeServiceIdListPayload(
    settings.bubbleVisibleServiceIds,
    services,
    [activeService?.id || settings.activeServiceId || '']
  );
  const glossary = normalizeGlossaryPayload(settings.glossary);
  const automation = normalizeAutomationPayload(settings.automation, DEFAULT_SETTINGS.automation);

  return {
    env: {
      TRANSLATE_SHORTCUT: env.TRANSLATE_SHORTCUT,
      OPEN_SETTINGS_SHORTCUT: env.OPEN_SETTINGS_SHORTCUT,
      POPUP_MODE: env.POPUP_MODE,
      TRANSLATOR_FONT_SIZE: env.TRANSLATOR_FONT_SIZE
    },
    services: services.map((service) => ({ ...service })),
    activeServiceId: activeService?.id || settings.activeServiceId || '',
    activeService: activeService ? { ...activeService } : null,
    routing,
    bubbleVisibleServiceIds,
    glossary,
    automation,
    effective: {
      translateShortcut: currentTranslateShortcut(),
      openSettingsShortcut: currentOpenSettingsShortcut(),
      popupMode: runtimeConfig?.popupMode || 'panel',
      fontSize: runtimeConfig?.fontSize || 16,
      activeServiceName: runtimeConfig?.activeServiceName || activeService?.name || ''
    },
    settingsPath: getSettingsPath()
  };
}

function buildNextSettingsFromPayload(payload) {
  const current = readSettings();
  const currentEnv = current.env || {};
  const nextEnv = {
    ...DEFAULT_SETTINGS.env,
    ...currentEnv
  };

  const payloadEnv = payload?.env && typeof payload.env === 'object' ? payload.env : payload;

  for (const key of GLOBAL_ENV_SETTING_KEYS) {
    if (typeof payloadEnv?.[key] === 'string') {
      nextEnv[key] = payloadEnv[key].trim();
    }
  }

  const envFallback = {
    ...DEFAULT_SETTINGS.env,
    ...nextEnv
  };

  const rawServices = Array.isArray(payload?.services) ? payload.services : current.services;
  let nextServices = Array.isArray(rawServices)
    ? rawServices.map((service, index) => sanitizeServicePayload(service, index, envFallback))
    : [];

  if (nextServices.length === 0) {
    nextServices = [sanitizeServicePayload({}, 0, envFallback)];
  }

  nextServices = dedupeServiceIds(nextServices);

  for (const service of nextServices) {
    if (!service.baseUrl) {
      throw new Error(`服务「${service.name}」缺少 Base URL`);
    }
    if (!service.model) {
      throw new Error(`服务「${service.name}」缺少模型名`);
    }
  }

  const requestedActiveServiceId =
    typeof payload?.activeServiceId === 'string' ? payload.activeServiceId.trim() : current.activeServiceId;
  const activeService = getActiveService(nextServices, requestedActiveServiceId);
  if (!activeService) {
    throw new Error('未找到可用服务，请至少保留一个服务配置');
  }
  const activeServiceId = activeService.id;

  nextEnv.ANTHROPIC_BASE_URL = activeService.baseUrl;
  nextEnv.ANTHROPIC_AUTH_TOKEN = activeService.apiKey;
  nextEnv.ANTHROPIC_MODEL = activeService.model;
  nextEnv.TARGET_LANGUAGE = activeService.targetLanguage;
  nextEnv.API_TIMEOUT_MS = activeService.timeoutMs;

  const popupMode = normalizePopupMode(nextEnv.POPUP_MODE);
  if (!['panel', 'bubble'].includes(popupMode)) {
    throw new Error('POPUP_MODE 仅支持 panel 或 bubble');
  }
  nextEnv.POPUP_MODE = popupMode;

  const fontSize = Number(nextEnv.TRANSLATOR_FONT_SIZE);
  if (!Number.isFinite(fontSize)) {
    throw new Error('TRANSLATOR_FONT_SIZE 必须是数字（推荐 12-32）');
  }
  nextEnv.TRANSLATOR_FONT_SIZE = String(clampToRange(Math.round(fontSize), 12, 32));

  if (!isLikelyValidAccelerator(nextEnv.TRANSLATE_SHORTCUT)) {
    throw new Error('TRANSLATE_SHORTCUT 格式无效，请使用类似 CommandOrControl+Shift+T 的组合');
  }

  if (!isLikelyValidAccelerator(nextEnv.OPEN_SETTINGS_SHORTCUT)) {
    throw new Error(
      'OPEN_SETTINGS_SHORTCUT 格式无效，请使用类似 CommandOrControl+Shift+O 的组合'
    );
  }

  if (
    nextEnv.TRANSLATE_SHORTCUT &&
    nextEnv.OPEN_SETTINGS_SHORTCUT &&
    nextEnv.TRANSLATE_SHORTCUT.toLowerCase() === nextEnv.OPEN_SETTINGS_SHORTCUT.toLowerCase()
  ) {
    throw new Error('翻译快捷键与偏好设置快捷键不能相同');
  }

  const nextRouting = normalizeRoutingPayload(payload?.routing, current.routing);
  const requestedBubbleVisibleServiceIds = Array.isArray(payload?.bubbleVisibleServiceIds)
    ? payload.bubbleVisibleServiceIds
    : current.bubbleVisibleServiceIds;
  const nextBubbleVisibleServiceIds = normalizeServiceIdListPayload(
    requestedBubbleVisibleServiceIds,
    nextServices,
    [activeServiceId]
  );
  const nextGlossary = Array.isArray(payload?.glossary)
    ? normalizeGlossaryPayload(payload.glossary)
    : normalizeGlossaryPayload(current.glossary);
  const nextAutomation = normalizeAutomationPayload(payload?.automation, current.automation);

  return {
    ...current,
    env: nextEnv,
    services: nextServices,
    activeServiceId,
    routing: nextRouting,
    bubbleVisibleServiceIds: nextBubbleVisibleServiceIds,
    glossary: nextGlossary,
    automation: nextAutomation
  };
}

function setupIpcHandlers() {
  ipcMain.on('translator:auto-resize', (_, payload) => {
    autoResizeTranslatorWindow(payload);
  });

  ipcMain.on('translator:set-bubble-pin', (_, payload) => {
    setBubblePinned(payload?.pinned === true);
  });

  ipcMain.handle('preferences:get-settings', () => {
    return toPreferencesResponse();
  });

  ipcMain.handle('preferences:save-settings', (_, payload) => {
    const nextSettings = buildNextSettingsFromPayload(payload);
    writeSettings(nextSettings);
    loadRuntimeConfig();
    applyRuntimeConfig();

    showNotification(APP_NAME, '偏好设置已保存并生效。');
    return {
      ok: true,
      ...toPreferencesResponse()
    };
  });

  ipcMain.handle('preferences:update-automation', (_, payload) => {
    const current = readSettings();
    const nextAutomation = normalizeAutomationPayload(payload, current.automation);
    writeSettings({
      ...current,
      automation: nextAutomation
    });
    loadRuntimeConfig();
    applyRuntimeConfig();

    return {
      ok: true,
      automation: getAutomationConfig()
    };
  });

  ipcMain.handle('preferences:clipboard-read-text', () => {
    return clipboard.readText() || '';
  });

  ipcMain.handle('preferences:clipboard-write-text', (_, text) => {
    clipboard.writeText(String(text || ''));
    return true;
  });

  ipcMain.handle('preferences:open-config-file', async () => {
    await shell.openPath(getSettingsPath());
    return true;
  });
}

app.whenReady().then(() => {
  app.setName(APP_NAME);
  if (process.platform === 'darwin' && app.dock) {
    app.dock.hide();
  }
  ensureConfigFiles();
  loadRuntimeConfig();
  createMainWindow();
  createPreferencesWindow();
  createTray();
  setupIpcHandlers();
  applyRuntimeConfig();
  if (process.platform === 'darwin') {
    ensureMacSelectionHelperBuilt();
    ensureMacClickMonitorHelperBuilt();
  }

  if (!runtimeConfig.apiKey || runtimeConfig.apiKey === 'REPLACE_WITH_YOUR_API_KEY') {
    showNotification(
      APP_NAME,
      `请先配置 API Key：${currentOpenSettingsShortcut()} 打开偏好设置`
    );
  }
});

app.on('before-quit', () => {
  isQuitting = true;
  stopMacGlobalClickMonitor();
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
  stopMacGlobalClickMonitor();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('activate', () => {
  if (!preferencesWindow || preferencesWindow.isDestroyed()) {
    createPreferencesWindow();
  }
  openPreferencesWindow();
});

app.on('second-instance', () => {
  openPreferencesWindow();
});
