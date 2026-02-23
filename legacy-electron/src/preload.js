const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('translatorApp', {
  onTranslationResult: (handler) => {
    ipcRenderer.on('translation-result', (_, payload) => handler(payload));
  },
  onShortcutsUpdated: (handler) => {
    ipcRenderer.on('shortcuts-updated', (_, payload) => handler(payload));
  },
  onUiConfigUpdated: (handler) => {
    ipcRenderer.on('ui-config-updated', (_, payload) => handler(payload));
  },
  onAutomationConfigUpdated: (handler) => {
    ipcRenderer.on('automation-config-updated', (_, payload) => handler(payload));
  },
  onWindowVisibility: (handler) => {
    ipcRenderer.on('window-visibility', (_, payload) => handler(payload));
  },
  onBubblePinUpdated: (handler) => {
    ipcRenderer.on('bubble-pin-updated', (_, payload) => handler(payload));
  },
  setBubblePinned: (pinned) => {
    ipcRenderer.send('translator:set-bubble-pin', { pinned: Boolean(pinned) });
  },
  requestWindowResize: (payload) => {
    ipcRenderer.send('translator:auto-resize', payload);
  }
});
