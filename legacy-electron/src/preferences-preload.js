const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('preferencesApi', {
  getSettings: () => ipcRenderer.invoke('preferences:get-settings'),
  saveSettings: (payload) => ipcRenderer.invoke('preferences:save-settings', payload),
  updateAutomation: (payload) => ipcRenderer.invoke('preferences:update-automation', payload),
  readClipboardText: () => ipcRenderer.invoke('preferences:clipboard-read-text'),
  writeClipboardText: (text) => ipcRenderer.invoke('preferences:clipboard-write-text', text),
  openRawSettingsFile: () => ipcRenderer.invoke('preferences:open-config-file')
});
