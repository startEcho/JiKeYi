const sourceNode = document.getElementById('source');
const resultNode = document.getElementById('result');
const resultPaneNode = document.getElementById('resultPane');
const serviceResultsNode = document.getElementById('serviceResults');
const sourceCountNode = document.getElementById('sourceCount');
const resultCountNode = document.getElementById('resultCount');
const statusBadgeNode = document.getElementById('statusBadge');
const modeBadgeNode = document.getElementById('modeBadge');
const shortcutBadgeNode = document.getElementById('shortcutBadge');
const metaNode = document.getElementById('meta');
const copyButton = document.getElementById('copyBtn');
const pinButton = document.getElementById('pinBtn');

let shortcutText = 'CommandOrControl+Shift+T';
let popupMode = 'panel';
let fontSize = 16;
let typingFrameHandle = 0;
let typingTargetChars = [];
let typingShownCount = 0;
let pendingDoneTime = '';
let countUpdateFrameHandle = 0;
let resizeTimerHandle = 0;
let lastResizeRequestAt = 0;
let pendingResizeStreaming = false;
let pendingResizeAllowShrink = false;
let lastResizePayload = null;
let lastResizeSignature = '';
let bubbleEnterTimerHandle = 0;
let bubblePinned = false;
let bubblePinAvailable = false;
let bubbleWindowVisible = false;
let latestServiceResults = [];
let serviceCardNodeMap = new Map();
let serviceRenderOrderKey = '';
let preferredServiceId = '';
const DEFAULT_AUTOMATION_CONFIG = {
  replaceLineBreaksWithSpace: false,
  stripCodeCommentMarkers: false,
  removeHyphenSpace: false,
  autoCopyOcrResult: false,
  autoCopyFirstResult: false,
  copyHighlightedWordOnClick: false,
  autoPlaySourceText: false
};
let automationConfig = { ...DEFAULT_AUTOMATION_CONFIG };
let hasAutoCopiedCurrentTask = false;
let hasAutoPlayedSourceCurrentTask = false;

function updateCount() {
  const sourceText = String(sourceNode.textContent || '');
  const sourceLength = sourceText.trim().length;
  const sourceLineCount = Math.max(
    1,
    sourceText.split(/\r\n|[\r\n\u000b\u000c\u0085\u2028\u2029]/).length
  );
  const resultLength =
    latestServiceResults.length > 0
      ? latestServiceResults.reduce((sum, service) => {
          const translation = String(service?.translation || '').trim();
          if (translation) {
            return sum + translation.length;
          }
          if (service?.status === 'error') {
            return sum + String(service?.error || '').trim().length;
          }
          return sum;
        }, 0)
      : resultNode.textContent.trim().length;
  sourceCountNode.textContent = `${sourceLength} 字 / ${sourceLineCount} 行`;
  resultCountNode.textContent = `${resultLength} 字`;
}

function scheduleCountUpdate() {
  if (countUpdateFrameHandle) {
    return;
  }
  countUpdateFrameHandle = requestAnimationFrame(() => {
    countUpdateFrameHandle = 0;
    updateCount();
  });
}

function flushCountUpdate() {
  if (countUpdateFrameHandle) {
    cancelAnimationFrame(countUpdateFrameHandle);
    countUpdateFrameHandle = 0;
  }
  updateCount();
}

function setStatusBadge(text, mode) {
  statusBadgeNode.textContent = text;
  statusBadgeNode.className = `badge ${mode || ''}`.trim();
}

function buildServiceMeta(payload) {
  if (!payload || typeof payload !== 'object') {
    return '';
  }

  if (payload.serviceMeta) {
    return String(payload.serviceMeta);
  }

  if (payload.serviceName) {
    return `服务：${payload.serviceName}`;
  }

  return '';
}

function applyAutomationConfig(payload) {
  const source = payload && typeof payload === 'object' ? payload : {};
  automationConfig = {
    ...DEFAULT_AUTOMATION_CONFIG,
    ...source
  };
}

function normalizeMarkdownSource(text) {
  let normalized = String(text || '');
  const hasRealLineBreak = /[\r\n]/.test(normalized);
  if (!hasRealLineBreak && /\\[nrt]/.test(normalized)) {
    normalized = normalized
      .replace(/\\r\\n/g, '\n')
      .replace(/\\n/g, '\n')
      .replace(/\\r/g, '\n')
      .replace(/\\t/g, '\t');
  }
  return normalized.replace(/\r\n?/g, '\n');
}

function escapeHtml(text) {
  return String(text || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function escapeHtmlAttribute(text) {
  return String(text || '')
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function sanitizeLinkUrl(rawUrl) {
  const url = String(rawUrl || '').trim();
  if (!url) {
    return '';
  }
  if (/^https?:\/\/[^\s]+$/i.test(url)) {
    return url;
  }
  if (/^mailto:[^\s]+$/i.test(url)) {
    return url;
  }
  return '';
}

function renderInlineMarkdown(text) {
  let html = escapeHtml(text);
  const placeholders = [];
  const stash = (fragment) => {
    const token = `\u0000${placeholders.length}\u0000`;
    placeholders.push(fragment);
    return token;
  };

  html = html.replace(/`([^`\n]+)`/g, (_, code) => stash(`<code>${code}</code>`));

  html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (match, label, url) => {
    const safeUrl = sanitizeLinkUrl(url);
    if (!safeUrl) {
      return label;
    }
    return `<a href="${escapeHtmlAttribute(
      safeUrl
    )}" target="_blank" rel="noopener noreferrer">${label}</a>`;
  });

  html = html.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
  html = html.replace(/__([^_\n]+)__/g, '<strong>$1</strong>');
  html = html.replace(/~~([^~\n]+)~~/g, '<del>$1</del>');
  html = html.replace(/\*([^*\n]+)\*/g, '<em>$1</em>');
  html = html.replace(/_([^_\n]+)_/g, '<em>$1</em>');

  return html.replace(/\u0000(\d+)\u0000/g, (match, indexText) => {
    const index = Number(indexText);
    if (!Number.isFinite(index) || index < 0 || index >= placeholders.length) {
      return '';
    }
    return placeholders[index];
  });
}

function splitTableRow(line) {
  const trimmed = String(line || '').trim();
  if (!trimmed) {
    return [];
  }
  const body = trimmed.replace(/^\|/, '').replace(/\|$/, '');
  return body.split('|').map((cell) => cell.trim());
}

function isTableDividerLine(line) {
  const cells = splitTableRow(line);
  if (cells.length < 1) {
    return false;
  }
  return cells.every((cell) => /^:?-{3,}:?$/.test(cell.replace(/\s+/g, '')));
}

function isTableRowLine(line) {
  return splitTableRow(line).length >= 2;
}

function getTableColumnAlignment(cell) {
  const token = String(cell || '').replace(/\s+/g, '');
  if (/^:-+:$/.test(token)) {
    return 'center';
  }
  if (/^-+:$/.test(token)) {
    return 'right';
  }
  if (/^:-+$/.test(token)) {
    return 'left';
  }
  return '';
}

function padCells(cells, size) {
  const next = [...cells];
  while (next.length < size) {
    next.push('');
  }
  return next.slice(0, size);
}

function renderTableBlock(lines, startIndex) {
  const headerCellsRaw = splitTableRow(lines[startIndex]);
  const dividerCells = splitTableRow(lines[startIndex + 1]);
  let index = startIndex + 2;
  const bodyRowsRaw = [];

  while (index < lines.length) {
    const line = String(lines[index] || '');
    if (!line.trim() || !isTableRowLine(line)) {
      break;
    }
    bodyRowsRaw.push(splitTableRow(line));
    index += 1;
  }

  const columnCount = Math.max(
    headerCellsRaw.length,
    dividerCells.length,
    ...bodyRowsRaw.map((cells) => cells.length)
  );
  const headerCells = padCells(headerCellsRaw, columnCount);
  const bodyRows = bodyRowsRaw.map((cells) => padCells(cells, columnCount));
  const alignments = padCells(dividerCells, columnCount).map(getTableColumnAlignment);

  let html = '<div class="md-table-wrap"><table><thead><tr>';
  for (let i = 0; i < columnCount; i += 1) {
    const align = alignments[i] ? ` style="text-align:${alignments[i]}"` : '';
    html += `<th${align}>${renderInlineMarkdown(headerCells[i])}</th>`;
  }
  html += '</tr></thead>';

  if (bodyRows.length > 0) {
    html += '<tbody>';
    for (const row of bodyRows) {
      html += '<tr>';
      for (let i = 0; i < columnCount; i += 1) {
        const align = alignments[i] ? ` style="text-align:${alignments[i]}"` : '';
        html += `<td${align}>${renderInlineMarkdown(row[i])}</td>`;
      }
      html += '</tr>';
    }
    html += '</tbody>';
  }

  html += '</table></div>';
  return {
    html,
    nextIndex: index
  };
}

function isHeadingLine(line) {
  return /^\s{0,3}#{1,6}\s+/.test(line);
}

function isHorizontalRuleLine(line) {
  return /^\s{0,3}(?:\*\s*){3,}$/.test(line) || /^\s{0,3}(?:-\s*){3,}$/.test(line);
}

function isFenceLine(line) {
  return /^\s*```/.test(line);
}

function isBlockquoteLine(line) {
  return /^\s*>/.test(line);
}

function isOrderedListLine(line) {
  return /^\s*\d+\.\s+/.test(line);
}

function isUnorderedListLine(line) {
  return /^\s*[-*+]\s+/.test(line);
}

function renderListBlock(lines, startIndex, ordered) {
  const itemPattern = ordered ? /^\s*\d+\.\s+/ : /^\s*[-*+]\s+/;
  const tag = ordered ? 'ol' : 'ul';
  const items = [];
  let index = startIndex;

  while (index < lines.length) {
    const currentLine = String(lines[index] || '');
    if (!itemPattern.test(currentLine)) {
      break;
    }

    const entryLines = [currentLine.replace(itemPattern, '').trim()];
    index += 1;

    while (index < lines.length) {
      const followLine = String(lines[index] || '');
      if (!followLine.trim()) {
        break;
      }
      if (itemPattern.test(followLine) || isOrderedListLine(followLine) || isUnorderedListLine(followLine)) {
        break;
      }
      if (/^\s{2,}\S/.test(followLine)) {
        entryLines.push(followLine.trim());
        index += 1;
        continue;
      }
      break;
    }

    const content = entryLines.map((line) => renderInlineMarkdown(line)).join('<br>');
    items.push(`<li>${content}</li>`);

    if (index < lines.length && !String(lines[index] || '').trim()) {
      index += 1;
      break;
    }
  }

  return {
    html: `<${tag}>${items.join('')}</${tag}>`,
    nextIndex: index
  };
}

function renderMarkdownToHtml(text) {
  const normalized = normalizeMarkdownSource(text);
  if (!normalized.trim()) {
    return '';
  }

  const lines = normalized.split('\n');
  const blocks = [];
  let index = 0;

  while (index < lines.length) {
    const line = String(lines[index] || '');
    if (!line.trim()) {
      index += 1;
      continue;
    }

    if (isFenceLine(line)) {
      const languageMatch = line.match(/^\s*```([A-Za-z0-9_-]+)?\s*$/);
      const language = languageMatch?.[1] ? ` class="language-${escapeHtmlAttribute(languageMatch[1])}"` : '';
      index += 1;
      const codeLines = [];
      while (index < lines.length && !isFenceLine(lines[index])) {
        codeLines.push(lines[index]);
        index += 1;
      }
      if (index < lines.length && isFenceLine(lines[index])) {
        index += 1;
      }
      blocks.push(`<pre><code${language}>${escapeHtml(codeLines.join('\n'))}</code></pre>`);
      continue;
    }

    if (
      index + 1 < lines.length &&
      isTableRowLine(line) &&
      isTableDividerLine(lines[index + 1])
    ) {
      const table = renderTableBlock(lines, index);
      blocks.push(table.html);
      index = table.nextIndex;
      continue;
    }

    const headingMatch = line.match(/^\s{0,3}(#{1,6})\s+(.*)$/);
    if (headingMatch) {
      const level = Math.min(6, headingMatch[1].length);
      const content = renderInlineMarkdown(headingMatch[2].trim());
      blocks.push(`<h${level}>${content}</h${level}>`);
      index += 1;
      continue;
    }

    if (isHorizontalRuleLine(line)) {
      blocks.push('<hr>');
      index += 1;
      continue;
    }

    if (isBlockquoteLine(line)) {
      const quoteLines = [];
      while (index < lines.length) {
        const quoteLine = String(lines[index] || '');
        const match = quoteLine.match(/^\s*>\s?(.*)$/);
        if (!match) {
          break;
        }
        quoteLines.push(renderInlineMarkdown(match[1]));
        index += 1;
      }
      blocks.push(`<blockquote>${quoteLines.join('<br>')}</blockquote>`);
      continue;
    }

    if (isOrderedListLine(line)) {
      const list = renderListBlock(lines, index, true);
      blocks.push(list.html);
      index = list.nextIndex;
      continue;
    }

    if (isUnorderedListLine(line)) {
      const list = renderListBlock(lines, index, false);
      blocks.push(list.html);
      index = list.nextIndex;
      continue;
    }

    const paragraphLines = [];
    while (index < lines.length) {
      const paragraphLine = String(lines[index] || '');
      if (!paragraphLine.trim()) {
        break;
      }
      if (
        isFenceLine(paragraphLine) ||
        isHeadingLine(paragraphLine) ||
        isHorizontalRuleLine(paragraphLine) ||
        isBlockquoteLine(paragraphLine) ||
        isOrderedListLine(paragraphLine) ||
        isUnorderedListLine(paragraphLine) ||
        (index + 1 < lines.length &&
          isTableRowLine(paragraphLine) &&
          isTableDividerLine(lines[index + 1]))
      ) {
        break;
      }
      paragraphLines.push(renderInlineMarkdown(paragraphLine));
      index += 1;
    }
    blocks.push(`<p>${paragraphLines.join('<br>')}</p>`);
  }

  return blocks.join('');
}

function setMarkdownContent(node, text) {
  if (!node) {
    return;
  }
  const normalized = String(text || '');
  if (node.__markdownSource === normalized) {
    return;
  }
  node.__markdownSource = normalized;
  const html = renderMarkdownToHtml(normalized);
  node.innerHTML = html || '';
}

function applyUiConfig() {
  document.documentElement.style.setProperty('--translator-font-size', `${fontSize}px`);
  document.body.classList.toggle('bubble-mode', popupMode === 'bubble');
  document.body.classList.remove('bubble-exit-active');
  modeBadgeNode.textContent = `模式：${popupMode} / 字体 ${fontSize}px`;
  lastResizeSignature = '';
  renderBubblePinButton();
  scheduleAdaptiveResize({ allowShrink: true });
}

function renderBubblePinButton() {
  if (!pinButton) {
    return;
  }

  const visible = popupMode === 'bubble' && bubblePinAvailable !== false;
  pinButton.style.display = visible ? 'inline-flex' : 'none';
  pinButton.disabled = !visible;
  pinButton.classList.toggle('active', bubblePinned);
  pinButton.textContent = bubblePinned ? '📌' : '📍';
  pinButton.title = bubblePinned ? '取消钉住气泡' : '钉住气泡';
  pinButton.setAttribute('aria-label', bubblePinned ? '取消钉住气泡' : '钉住气泡');
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function isWideChar(char) {
  return /[\u2e80-\u9fff\uf900-\ufaff\u3000-\u303f\uff00-\uffef]/.test(char);
}

function countTextUnits(line) {
  let units = 0;
  for (const char of String(line || '')) {
    units += isWideChar(char) ? 2 : 1;
  }
  return units;
}

function longestLineUnits(text) {
  const lines = String(text || '')
    .split(/\r?\n/)
    .slice(0, 120);
  let maxUnits = 0;
  for (const line of lines) {
    maxUnits = Math.max(maxUnits, countTextUnits(line));
  }
  return maxUnits;
}

function estimateAdaptiveWidth() {
  const sourceText = sourceNode.textContent || '';
  const resultText =
    latestServiceResults.length > 0
      ? latestServiceResults
          .map((service) => {
            const modelText = service.model ? ` / ${service.model}` : '';
            const body = String(service.translation || service.error || '').trim();
            return `[${service.name}${modelText}] ${body}`;
          })
          .join('\n')
      : resultNode.textContent || '';
  const maxLen = Math.max(sourceText.trim().length, resultText.trim().length);
  const maxLineUnits = Math.max(longestLineUnits(sourceText), longestLineUnits(resultText));

  if (popupMode === 'bubble') {
    const widthByLine = maxLineUnits * (fontSize * 0.54) + 120;
    const widthByLength = 520 + Math.sqrt(Math.max(0, maxLen)) * 8;
    return clamp(Math.round(Math.max(520, widthByLine, widthByLength)), 520, 920);
  }

  const paneWidthByLine = maxLineUnits * (fontSize * 0.42) + 130;
  const paneWidthByLength = 330 + Math.sqrt(Math.max(0, maxLen)) * 8;
  const paneWidth = Math.max(320, paneWidthByLine, paneWidthByLength);
  return clamp(Math.round(paneWidth * 2 + 44), 760, 1360);
}

function estimateAdaptiveHeight(options = {}) {
  const allowShrink = Boolean(options.allowShrink);
  const sourceOverflow = Math.max(0, sourceNode.scrollHeight - sourceNode.clientHeight);
  const resultOverflow = Math.max(0, resultPaneNode.scrollHeight - resultPaneNode.clientHeight);

  const expandBy =
    popupMode === 'bubble'
      ? sourceOverflow + resultOverflow
      : Math.max(sourceOverflow, resultOverflow);

  const currentHeight = Math.max(window.innerHeight || 0, popupMode === 'bubble' ? 380 : 520);
  const minHeight = popupMode === 'bubble' ? 380 : 520;
  const maxHeight = popupMode === 'bubble' ? 980 : 1040;
  if (expandBy > 0) {
    return clamp(Math.round(currentHeight + expandBy), minHeight, maxHeight);
  }

  if (!allowShrink) {
    return clamp(currentHeight, minHeight, maxHeight);
  }

  const sourceSpare = Math.max(0, sourceNode.clientHeight - sourceNode.scrollHeight);
  const resultSpare = Math.max(0, resultPaneNode.clientHeight - resultPaneNode.scrollHeight);
  const totalSpare =
    popupMode === 'bubble' ? sourceSpare + resultSpare : Math.max(sourceSpare, resultSpare);
  const shrinkGuard = popupMode === 'bubble' ? 42 : 52;
  const shrinkBy = Math.max(0, Math.round(totalSpare - shrinkGuard));
  if (shrinkBy <= 0) {
    return clamp(currentHeight, minHeight, maxHeight);
  }

  return clamp(Math.round(currentHeight - shrinkBy), minHeight, maxHeight);
}

function buildResizePayload(options = {}) {
  const allowShrink = Boolean(options.allowShrink);
  return {
    popupMode,
    allowShrink,
    height: estimateAdaptiveHeight({ allowShrink })
  };
}

function buildResizeSignature(options = {}) {
  const allowShrink = Boolean(options.allowShrink);
  const sourceLen = String(sourceNode.textContent || '').trim().length;
  if (latestServiceResults.length > 0) {
    let textLen = 0;
    let done = 0;
    let error = 0;
    let streaming = 0;
    let running = 0;
    for (const service of latestServiceResults) {
      textLen += String(service.translation || service.error || '').trim().length;
      const status = String(service.status || '').toLowerCase();
      if (status === 'done') {
        done += 1;
      } else if (status === 'error') {
        error += 1;
      } else if (status === 'streaming') {
        streaming += 1;
      } else if (status === 'running') {
        running += 1;
      }
    }
    return `${popupMode}|${allowShrink ? '1' : '0'}|svc:${latestServiceResults.length}:${sourceLen}:${textLen}:${done}:${error}:${streaming}:${running}`;
  }

  const resultLen = String(resultNode.textContent || '').trim().length;
  return `${popupMode}|${allowShrink ? '1' : '0'}|single:${sourceLen}:${resultLen}`;
}

function shouldSendResize(payload) {
  if (!lastResizePayload) {
    return true;
  }

  if (payload.popupMode !== lastResizePayload.popupMode) {
    return true;
  }

  if (!payload.allowShrink && payload.height < lastResizePayload.height) {
    return false;
  }

  const heightThreshold =
    payload.popupMode === 'bubble'
      ? payload.allowShrink
        ? 10
        : 6
      : payload.allowShrink
        ? 16
        : 12;
  if (Math.abs(payload.height - lastResizePayload.height) >= heightThreshold) {
    return true;
  }

  return false;
}

function requestAdaptiveResize(options = {}) {
  if (!window.translatorApp?.requestWindowResize) {
    return;
  }

  const signature = buildResizeSignature(options);
  if (signature === lastResizeSignature && !options?.allowShrink) {
    return;
  }
  lastResizeSignature = signature;

  const payload = buildResizePayload(options);
  if (!shouldSendResize(payload)) {
    return;
  }

  lastResizePayload = payload;
  window.translatorApp.requestWindowResize(payload);
}

function scheduleAdaptiveResize(options = {}) {
  const streaming = Boolean(options.streaming);
  const allowShrink = Boolean(options.allowShrink);

  pendingResizeStreaming = pendingResizeStreaming || streaming;
  pendingResizeAllowShrink = pendingResizeAllowShrink || allowShrink;

  if (resizeTimerHandle) {
    return;
  }

  const now = Date.now();
  let minInterval = pendingResizeStreaming ? 120 : 64;
  if (popupMode === 'bubble') {
    minInterval = pendingResizeStreaming ? 96 : 48;
  }
  const waitMs = Math.max(0, minInterval - (now - lastResizeRequestAt));

  resizeTimerHandle = window.setTimeout(() => {
    resizeTimerHandle = 0;
    const shouldAllowShrink = pendingResizeAllowShrink;
    pendingResizeStreaming = false;
    pendingResizeAllowShrink = false;
    window.requestAnimationFrame(() => {
      requestAdaptiveResize({ allowShrink: shouldAllowShrink });
      lastResizeRequestAt = Date.now();
    });
  }, waitMs);
}

function stopTypingAnimation() {
  if (typingFrameHandle) {
    cancelAnimationFrame(typingFrameHandle);
    typingFrameHandle = 0;
  }
}

function resetTypingState() {
  stopTypingAnimation();
  typingTargetChars = [];
  typingShownCount = 0;
  pendingDoneTime = '';
}

function applyDoneStateIfNeeded() {
  if (!pendingDoneTime) {
    return;
  }

  setStatusBadge('翻译完成', 'ok');
  metaNode.textContent = `完成时间：${pendingDoneTime}`;
  pendingDoneTime = '';
  flushCountUpdate();
}

function renderTypingFrame() {
  typingFrameHandle = 0;

  const remaining = typingTargetChars.length - typingShownCount;
  if (remaining <= 0) {
    applyDoneStateIfNeeded();
    return;
  }

  const minStep = popupMode === 'bubble' ? 1 : 2;
  const dynamicStep = popupMode === 'bubble' ? Math.ceil(remaining / 24) : Math.ceil(remaining / 10);
  const step = Math.min(remaining, Math.max(minStep, dynamicStep));
  typingShownCount += step;
  showSingleResultText(typingTargetChars.slice(0, typingShownCount).join(''));
  scheduleCountUpdate();
  scheduleAdaptiveResize({ streaming: true });
  typingFrameHandle = requestAnimationFrame(renderTypingFrame);
}

function restartBubbleEntryMotion() {
  if (popupMode !== 'bubble') {
    return;
  }

  if (bubbleEnterTimerHandle) {
    clearTimeout(bubbleEnterTimerHandle);
    bubbleEnterTimerHandle = 0;
  }

  document.body.classList.remove('bubble-enter-active');
  void document.body.offsetWidth;
  document.body.classList.add('bubble-enter-active');
  bubbleEnterTimerHandle = window.setTimeout(() => {
    document.body.classList.remove('bubble-enter-active');
    bubbleEnterTimerHandle = 0;
  }, 220);
}

function queueTypingResult(text, options = {}) {
  const { isFinal = false } = options;
  const normalized = text || '';

  typingTargetChars = Array.from(normalized);
  if (typingShownCount > typingTargetChars.length) {
    typingShownCount = 0;
  }

  if (isFinal) {
    pendingDoneTime = new Date().toLocaleTimeString();
  }

  if (typingTargetChars.length === 0) {
    stopTypingAnimation();
    typingShownCount = 0;
    showSingleResultText('（无译文）');
    flushCountUpdate();
    applyDoneStateIfNeeded();
    scheduleAdaptiveResize({ allowShrink: true });
    return;
  }

  if (typingShownCount >= typingTargetChars.length) {
    showSingleResultText(typingTargetChars.join(''));
    flushCountUpdate();
    applyDoneStateIfNeeded();
    scheduleAdaptiveResize({ allowShrink: isFinal });
    return;
  }

  if (!typingFrameHandle) {
    typingFrameHandle = requestAnimationFrame(renderTypingFrame);
  }
}

function hideServiceCards() {
  if (serviceResultsNode) {
    serviceResultsNode.hidden = true;
    serviceResultsNode.innerHTML = '';
  }
  serviceCardNodeMap.clear();
  serviceRenderOrderKey = '';
}

function showSingleResultText(text) {
  hideServiceCards();
  if (resultNode) {
    resultNode.hidden = false;
    setMarkdownContent(resultNode, String(text || ''));
  }
}

function getServiceOrderKey(services) {
  return services.map((item) => item.id).join('|');
}

function buildServiceBodyText(service) {
  const translationText = String(service.translation || '').trim();
  const errorText = String(service.error || '').trim();
  if (translationText) {
    if (service.status === 'error' && errorText) {
      return `${translationText}\n\n错误：${errorText}`;
    }
    return translationText;
  }
  if (service.status === 'error') {
    return `错误：${errorText || '请求失败'}`;
  }
  return '（进行中...）';
}

function applyServiceCardState(nodes, service) {
  if (!nodes || !service) {
    return;
  }
  const serviceName = service.name || '未命名服务';
  const translationText = String(service.translation || '').trim();
  nodes.card.className = `service-card status-${service.status || 'pending'}`;
  nodes.nameText.textContent = serviceName;
  nodes.modelText.textContent = service.model ? `/${service.model}` : '';
  nodes.modelText.hidden = !service.model;
  nodes.state.textContent = serviceStatusLabel(service);
  nodes.body.className = `service-card-body${service.status === 'error' ? ' error' : ''}`;
  setMarkdownContent(nodes.body, buildServiceBodyText(service));
  nodes.speakButton.disabled = !translationText;
  nodes.speakButton.title = `朗读 ${serviceName} 译文`;
  nodes.speakButton.setAttribute('aria-label', nodes.speakButton.title);
  nodes.copyButton.disabled = !translationText;
  nodes.copyButton.title = `复制 ${serviceName} 结果`;
  nodes.copyButton.setAttribute('aria-label', nodes.copyButton.title);
  nodes.preferButton.disabled = !translationText;
  const isPreferred = Boolean(preferredServiceId) && preferredServiceId === service.id;
  nodes.preferButton.classList.toggle('active', isPreferred);
  nodes.preferButton.title = isPreferred ? '已设为优先复制' : '设为优先复制';
  nodes.preferButton.setAttribute('aria-label', nodes.preferButton.title);
}

function createServiceCardNodes(service) {
  const card = document.createElement('article');
  const header = document.createElement('header');
  const title = document.createElement('div');
  const dot = document.createElement('span');
  const nameText = document.createElement('span');
  const modelText = document.createElement('span');
  const meta = document.createElement('div');
  const state = document.createElement('span');
  const body = document.createElement('div');
  const actions = document.createElement('footer');
  const speakButton = document.createElement('button');
  const copyButton = document.createElement('button');
  const preferButton = document.createElement('button');

  header.className = 'service-card-head';
  title.className = 'service-card-title';
  dot.className = 'service-dot';
  modelText.className = 'service-card-model';
  meta.className = 'service-card-meta';
  state.className = 'service-card-state';
  actions.className = 'service-card-actions';
  speakButton.className = 'service-action-btn';
  copyButton.className = 'service-action-btn service-copy-btn';
  preferButton.className = 'service-action-btn';

  speakButton.type = 'button';
  copyButton.type = 'button';
  preferButton.type = 'button';

  speakButton.textContent = '🔊';
  copyButton.textContent = '📋';
  preferButton.textContent = '↗';

  body.dataset.serviceId = service.id;
  speakButton.dataset.action = 'speak-service-result';
  speakButton.dataset.serviceId = service.id;
  copyButton.dataset.action = 'copy-service-result';
  copyButton.dataset.serviceId = service.id;
  preferButton.dataset.action = 'prefer-service-result';
  preferButton.dataset.serviceId = service.id;

  title.appendChild(dot);
  title.appendChild(nameText);
  title.appendChild(modelText);
  meta.appendChild(state);
  header.appendChild(title);
  header.appendChild(meta);
  card.appendChild(header);
  card.appendChild(body);
  actions.appendChild(speakButton);
  actions.appendChild(copyButton);
  actions.appendChild(preferButton);
  card.appendChild(actions);

  const nodes = {
    card,
    body,
    nameText,
    modelText,
    state,
    speakButton,
    copyButton,
    preferButton
  };
  applyServiceCardState(nodes, service);
  return nodes;
}

function rebuildServiceCards(services) {
  serviceResultsNode.innerHTML = '';
  serviceCardNodeMap.clear();
  for (const service of services) {
    const nodes = createServiceCardNodes(service);
    serviceCardNodeMap.set(service.id, nodes);
    serviceResultsNode.appendChild(nodes.card);
  }
  serviceRenderOrderKey = getServiceOrderKey(services);
}

function renderServiceResultCards(services, options = {}) {
  if (!serviceResultsNode || !resultNode) {
    return;
  }

  const changedServiceId = String(options?.changedServiceId || '').trim();
  const forceFull = options?.forceFull === true;
  const orderKey = getServiceOrderKey(services);
  const canPatch =
    !forceFull &&
    serviceCardNodeMap.size > 0 &&
    serviceCardNodeMap.size === services.length &&
    serviceRenderOrderKey === orderKey;

  resultNode.hidden = true;
  serviceResultsNode.hidden = false;

  if (!canPatch) {
    rebuildServiceCards(services);
    return;
  }

  if (changedServiceId) {
    const changedService = services.find((service) => service.id === changedServiceId);
    const nodes = changedService ? serviceCardNodeMap.get(changedService.id) : null;
    if (!changedService || !nodes) {
      rebuildServiceCards(services);
      return;
    }
    applyServiceCardState(nodes, changedService);
    return;
  }

  for (const service of services) {
    const nodes = serviceCardNodeMap.get(service.id);
    if (!nodes) {
      rebuildServiceCards(services);
      return;
    }
    applyServiceCardState(nodes, service);
  }
}

function normalizeServiceResults(rawServices) {
  if (!Array.isArray(rawServices)) {
    return [];
  }

  return rawServices
    .map((item, index) => ({
      id: String(item?.id || '').trim() || `service_${index + 1}`,
      name: String(item?.name || '').trim() || '未命名服务',
      model: String(item?.model || '').trim(),
      order: Number.isFinite(Number(item?.order)) ? Number(item.order) : index,
      status: String(item?.status || 'pending').trim() || 'pending',
      translation: String(item?.translation || ''),
      error: String(item?.error || '')
    }))
    .sort((a, b) => {
      if (a.order !== b.order) {
        return a.order - b.order;
      }
      return a.name.localeCompare(b.name, 'zh-CN');
    });
}

function mergeServiceDelta(rawDelta, mode = 'replace') {
  const deltaId = String(rawDelta?.id || '').trim();
  if (!deltaId) {
    return [...latestServiceResults];
  }

  const next = [...latestServiceResults];
  const index = next.findIndex((item) => item.id === deltaId);
  const current = index >= 0 ? next[index] : null;

  if (mode === 'append') {
    const safeCurrent = current || {
      id: deltaId,
      name: '未命名服务',
      model: '',
      order: next.length,
      status: 'streaming',
      translation: '',
      error: ''
    };

    const appendChunk = String(rawDelta?.translationDelta || '');
    let nextTranslation = String(safeCurrent.translation || '');
    if (appendChunk) {
      nextTranslation += appendChunk;
    }
    const expectedLength = Number(rawDelta?.translationLength);
    if (Number.isFinite(expectedLength) && expectedLength >= 0 && nextTranslation.length > expectedLength) {
      nextTranslation = nextTranslation.slice(0, expectedLength);
    }

    const merged = {
      ...safeCurrent,
      id: deltaId,
      status: String(rawDelta?.status || safeCurrent.status || 'streaming').trim() || 'streaming',
      error: String(rawDelta?.error || safeCurrent.error || ''),
      translation: nextTranslation
    };

    if (index >= 0) {
      next[index] = merged;
    } else {
      next.push(merged);
    }
  } else {
    const normalizedDelta = normalizeServiceResults([
      {
        ...(current || {}),
        ...(rawDelta || {}),
        id: deltaId,
        order: Number.isFinite(Number(rawDelta?.order))
          ? Number(rawDelta.order)
          : current?.order ?? next.length
      }
    ]);
    if (normalizedDelta.length === 0) {
      return [...latestServiceResults];
    }

    const delta = normalizedDelta[0];
    if (index >= 0) {
      next[index] = {
        ...current,
        ...delta
      };
    } else {
      next.push(delta);
    }
  }

  return next.sort((a, b) => {
    if (a.order !== b.order) {
      return a.order - b.order;
    }
    return a.name.localeCompare(b.name, 'zh-CN');
  });
}

function serviceStatusLabel(service) {
  const status = String(service?.status || '').toLowerCase();
  if (status === 'done') {
    return '已完成';
  }
  if (status === 'error') {
    return '失败';
  }
  if (status === 'streaming') {
    return '流式中';
  }
  if (status === 'running') {
    return '请求中';
  }
  return '等待中';
}

function summarizeServiceProgress(summary, services) {
  const normalizedSummary = summary && typeof summary === 'object' ? summary : {};
  const total = Number(normalizedSummary.total) || services.length;
  const done = Number(normalizedSummary.done) || 0;
  const error = Number(normalizedSummary.error) || 0;
  const running = Number(normalizedSummary.running) || 0;
  const streaming = Number(normalizedSummary.streaming) || 0;
  const pending = Number(normalizedSummary.pending) || Math.max(0, total - done - error - running - streaming);
  return { total, done, error, running, streaming, pending };
}

function findFirstSuccessfulService(services) {
  return services.find(
    (service) => service.status === 'done' && String(service.translation || '').trim().length > 0
  );
}

function findPreferredSuccessfulService(services) {
  const preferredId = String(preferredServiceId || '').trim();
  if (!preferredId) {
    return null;
  }
  return (
    services.find(
      (service) =>
        service.id === preferredId &&
        service.status === 'done' &&
        String(service.translation || '').trim().length > 0
    ) || null
  );
}

async function copyResultText() {
  let text = resultNode.textContent || '';
  let copyLabel = '译文已复制';

  if (latestServiceResults.length > 0) {
    const firstSuccess =
      findPreferredSuccessfulService(latestServiceResults) ||
      findFirstSuccessfulService(latestServiceResults);
    if (firstSuccess) {
      text = String(firstSuccess.translation || '');
      copyLabel = `已复制 ${firstSuccess.name} 译文`;
    }
  }

  if (!text.trim() || text === '等待翻译...' || text === '（无译文）') {
    return;
  }

  try {
    await navigator.clipboard.writeText(text);
    setStatusBadge(copyLabel, 'ok');
  } catch {
    setStatusBadge('复制失败', 'error');
  }
}

async function copyServiceResultText(serviceId) {
  const id = String(serviceId || '').trim();
  if (!id) {
    return;
  }
  const service = latestServiceResults.find((item) => item.id === id);
  const text = String(service?.translation || '').trim();
  if (!text) {
    return;
  }

  try {
    await navigator.clipboard.writeText(text);
    setStatusBadge(`已复制 ${service.name} 译文`, 'ok');
  } catch {
    setStatusBadge('复制失败', 'error');
  }
}

function speakText(text) {
  const content = String(text || '').trim();
  if (!content || !window.speechSynthesis || typeof window.SpeechSynthesisUtterance !== 'function') {
    return false;
  }

  try {
    const utterance = new window.SpeechSynthesisUtterance(content);
    utterance.rate = 1;
    utterance.pitch = 1;
    window.speechSynthesis.cancel();
    window.speechSynthesis.speak(utterance);
    return true;
  } catch {
    return false;
  }
}

function speakServiceResultText(serviceId) {
  const id = String(serviceId || '').trim();
  if (!id) {
    return;
  }
  const service = latestServiceResults.find((item) => item.id === id);
  const ok = speakText(service?.translation || '');
  if (ok) {
    setStatusBadge(`朗读 ${service?.name || '服务'} 中`, 'ok');
  }
}

function setPreferredService(serviceId) {
  const id = String(serviceId || '').trim();
  if (!id) {
    return;
  }
  preferredServiceId = id;
  renderServiceResultCards(latestServiceResults);
  const service = latestServiceResults.find((item) => item.id === id);
  if (service?.name) {
    metaNode.textContent = `已将 ${service.name} 设为优先复制服务`;
  }
}

function getSelectedText() {
  const selection = window.getSelection?.();
  if (!selection || selection.rangeCount <= 0 || selection.isCollapsed) {
    return '';
  }
  return String(selection.toString() || '');
}

async function copySelectedText() {
  const selectedText = getSelectedText();
  if (!selectedText) {
    return false;
  }
  try {
    await navigator.clipboard.writeText(selectedText);
    setStatusBadge('已复制选中文本', 'ok');
    return true;
  } catch {
    setStatusBadge('复制失败', 'error');
    return false;
  }
}

async function autoCopyText(text, metaMessage) {
  const content = String(text || '').trim();
  if (!content) {
    return;
  }
  try {
    await navigator.clipboard.writeText(content);
    setStatusBadge('已自动复制', 'ok');
    if (metaMessage) {
      metaNode.textContent = metaMessage;
    }
  } catch {
    // Ignore clipboard errors for automation behavior.
  }
}

function shouldAutoCopyForPayload(payload) {
  const sourceType = String(payload?.sourceType || '').toLowerCase();
  if (sourceType === 'ocr') {
    return automationConfig.autoCopyOcrResult;
  }
  return automationConfig.autoCopyFirstResult;
}

function stopAutoPlaySourceText() {
  if (!window.speechSynthesis) {
    return;
  }
  try {
    window.speechSynthesis.cancel();
  } catch {
    // Ignore browser speech synthesis failures.
  }
}

function maybeAutoPlaySourceText(sourceText) {
  if (!automationConfig.autoPlaySourceText || hasAutoPlayedSourceCurrentTask) {
    return;
  }

  const text = String(sourceText || '').trim();
  if (!text || text.length > 2400 || !window.speechSynthesis) {
    return;
  }
  if (typeof window.SpeechSynthesisUtterance !== 'function') {
    return;
  }

  stopAutoPlaySourceText();
  try {
    const utterance = new window.SpeechSynthesisUtterance(text);
    utterance.rate = 1;
    utterance.pitch = 1;
    window.speechSynthesis.speak(utterance);
    hasAutoPlayedSourceCurrentTask = true;
  } catch {
    // Ignore speech synthesis failures.
  }
}

async function maybeAutoCopyTranslation(payload) {
  if (hasAutoCopiedCurrentTask || !shouldAutoCopyForPayload(payload)) {
    return;
  }

  let text = '';
  let metaMessage = '已自动复制本次首个译文结果';
  const services = normalizeServiceResults(payload?.services);
  if (services.length > 0) {
    const firstSuccess = findFirstSuccessfulService(services);
    if (firstSuccess) {
      text = String(firstSuccess.translation || '').trim();
      metaMessage = `已自动复制服务「${firstSuccess.name}」译文`;
    }
  }

  if (!text) {
    text = String(payload?.translation || '').trim();
  }
  if (!text) {
    return;
  }

  hasAutoCopiedCurrentTask = true;
  if (String(payload?.sourceType || '').toLowerCase() === 'ocr') {
    await autoCopyText(text, '已自动复制 OCR 译文结果');
    return;
  }
  await autoCopyText(text, metaMessage);
}

function caretRangeFromPoint(clientX, clientY) {
  if (typeof document.caretRangeFromPoint === 'function') {
    return document.caretRangeFromPoint(clientX, clientY);
  }
  if (typeof document.caretPositionFromPoint === 'function') {
    const caretPosition = document.caretPositionFromPoint(clientX, clientY);
    if (!caretPosition) {
      return null;
    }
    const range = document.createRange();
    range.setStart(caretPosition.offsetNode, caretPosition.offset);
    range.collapse(true);
    return range;
  }
  return null;
}

function extractEnglishWordAtPoint(container, clientX, clientY) {
  const range = caretRangeFromPoint(clientX, clientY);
  if (!range) {
    return '';
  }

  const node = range.startContainer;
  if (!node || !container.contains(node) || node.nodeType !== Node.TEXT_NODE) {
    return '';
  }

  const text = node.textContent || '';
  if (!text) {
    return '';
  }

  let index = Math.max(0, Math.min(range.startOffset, text.length - 1));
  if (!/[A-Za-z]/.test(text[index] || '') && index > 0 && /[A-Za-z]/.test(text[index - 1])) {
    index -= 1;
  }
  if (!/[A-Za-z]/.test(text[index] || '')) {
    return '';
  }

  const wordCharRegex = /[A-Za-z0-9_'/-]/;
  let start = index;
  while (start > 0 && wordCharRegex.test(text[start - 1])) {
    start -= 1;
  }
  let end = index + 1;
  while (end < text.length && wordCharRegex.test(text[end])) {
    end += 1;
  }

  const word = text.slice(start, end).trim();
  if (!/^[A-Za-z]/.test(word)) {
    return '';
  }
  return word;
}

copyButton.addEventListener('click', () => {
  copyResultText();
});

pinButton?.addEventListener('click', () => {
  if (!window.translatorApp?.setBubblePinned) {
    return;
  }
  window.translatorApp.setBubblePinned(!bubblePinned);
});

resultNode.addEventListener('click', async (event) => {
  if (!automationConfig.copyHighlightedWordOnClick) {
    return;
  }

  const selectedText = String(window.getSelection?.()?.toString?.() || '').trim();
  if (selectedText) {
    return;
  }

  const word = extractEnglishWordAtPoint(resultNode, event.clientX, event.clientY);
  if (!word) {
    return;
  }

  await autoCopyText(word, `已复制单词：${word}`);
});

serviceResultsNode?.addEventListener('click', (event) => {
  const actionButton = event.target.closest('button[data-action]');
  if (actionButton) {
    const action = String(actionButton.dataset.action || '').trim();
    const serviceId = actionButton.dataset.serviceId;
    if (action === 'copy-service-result') {
      copyServiceResultText(serviceId);
      return;
    }
    if (action === 'speak-service-result') {
      speakServiceResultText(serviceId);
      return;
    }
    if (action === 'prefer-service-result') {
      setPreferredService(serviceId);
      return;
    }
  }

  if (!automationConfig.copyHighlightedWordOnClick) {
    return;
  }
  const selectedText = String(window.getSelection?.()?.toString?.() || '').trim();
  if (selectedText) {
    return;
  }
  const contentNode = event.target.closest('.service-card-body');
  if (!contentNode) {
    return;
  }
  const word = extractEnglishWordAtPoint(contentNode, event.clientX, event.clientY);
  if (!word) {
    return;
  }
  autoCopyText(word, `已复制单词：${word}`);
});

document.addEventListener('keydown', async (event) => {
  const key = String(event.key || '').toLowerCase();
  const isCopyShortcut = key === 'c' && (event.metaKey || event.ctrlKey) && !event.altKey;
  if (!isCopyShortcut) {
    return;
  }

  const active = document.activeElement;
  const tagName = String(active?.tagName || '').toLowerCase();
  if (tagName === 'input' || tagName === 'textarea' || active?.isContentEditable) {
    return;
  }

  if (await copySelectedText()) {
    event.preventDefault();
    return;
  }

  event.preventDefault();
  copyResultText();
});

window.translatorApp.onShortcutsUpdated((payload) => {
  if (payload.translateShortcut) {
    shortcutText = payload.translateShortcut;
    shortcutBadgeNode.textContent = `快捷键：${shortcutText}`;
    metaNode.textContent = '准备就绪，可随时触发翻译';
  }
});

window.translatorApp.onUiConfigUpdated((payload) => {
  popupMode = payload.popupMode === 'bubble' ? 'bubble' : 'panel';
  const parsedFont = Number(payload.fontSize);
  if (Number.isFinite(parsedFont)) {
    fontSize = Math.min(32, Math.max(12, Math.round(parsedFont)));
  }
  applyUiConfig();
});

window.translatorApp.onBubblePinUpdated((payload) => {
  bubblePinned = payload?.pinned === true;
  bubblePinAvailable = payload?.available !== false;
  renderBubblePinButton();
});

window.translatorApp.onAutomationConfigUpdated((payload) => {
  applyAutomationConfig(payload);
});

window.translatorApp.onWindowVisibility((payload) => {
  if (popupMode !== 'bubble') {
    return;
  }

  if (payload?.visible === false) {
    bubbleWindowVisible = false;
    if (bubblePinned || payload?.pinned === true) {
      return;
    }
    stopAutoPlaySourceText();
    document.body.classList.remove('bubble-enter-active');
    document.body.classList.add('bubble-exit-active');
    return;
  }

  if (bubbleWindowVisible) {
    document.body.classList.remove('bubble-exit-active');
    return;
  }

  bubbleWindowVisible = true;
  document.body.classList.remove('bubble-exit-active');
  restartBubbleEntryMotion();
});

window.translatorApp.onTranslationResult((payload) => {
  if (Object.prototype.hasOwnProperty.call(payload || {}, 'sourceText')) {
    const sourceText = String(payload?.sourceText || '');
    sourceNode.textContent = sourceText || '（空）';
  }

  if (payload.stage === 'reading') {
    hasAutoCopiedCurrentTask = false;
    hasAutoPlayedSourceCurrentTask = false;
    latestServiceResults = [];
    preferredServiceId = '';
    lastResizeSignature = '';
    stopAutoPlaySourceText();
    resetTypingState();
    showSingleResultText(payload.translation || '正在读取选中文本...');
    setStatusBadge('读取中...', 'pending');
    metaNode.textContent = '正在尝试读取你当前选中的文本';
    flushCountUpdate();
    scheduleAdaptiveResize({ allowShrink: false });
    return;
  }

  const snapshotServices = normalizeServiceResults(payload?.services);
  const hasSnapshotServices = snapshotServices.length > 0;
  const hasServiceDelta = Boolean(payload?.serviceDelta && typeof payload.serviceDelta === 'object');
  const serviceDeltaMode = String(payload?.serviceDeltaMode || 'replace').trim() || 'replace';
  const changedServiceId = String(
    payload?.changedServiceId || payload?.serviceDelta?.id || ''
  ).trim();
  const serviceResults = hasSnapshotServices
    ? snapshotServices
    : hasServiceDelta
      ? mergeServiceDelta(payload.serviceDelta, serviceDeltaMode)
      : [];

  if (serviceResults.length > 0) {
    maybeAutoPlaySourceText(sourceNode.textContent || '');
    latestServiceResults = serviceResults;
    resetTypingState();
    renderServiceResultCards(serviceResults, {
      changedServiceId: hasServiceDelta ? changedServiceId : ''
    });
    scheduleCountUpdate();
    const isStreamingAppendDelta = hasServiceDelta && serviceDeltaMode === 'append';
    if (!isStreamingAppendDelta) {
      maybeAutoCopyTranslation({
        ...payload,
        services: serviceResults
      });
    }

    const progress = summarizeServiceProgress(payload?.summary, serviceResults);
    if (payload.stage === 'all-done') {
      if (progress.done > 0) {
        setStatusBadge(`完成 ${progress.done}/${progress.total}`, 'ok');
      } else {
        setStatusBadge('全部失败', 'error');
      }
      const summaryText = `服务完成：成功 ${progress.done} / 失败 ${progress.error} / 总计 ${progress.total}`;
      metaNode.textContent = payload.error ? `${payload.error} ｜ ${summaryText}` : summaryText;
      scheduleAdaptiveResize({ allowShrink: true, streaming: false });
      return;
    }

    if (progress.done === 0 && progress.error === progress.total && progress.total > 0) {
      setStatusBadge('全部失败', 'error');
      metaNode.textContent = `所有服务均失败，共 ${progress.total} 个服务`;
      scheduleAdaptiveResize({ allowShrink: true, streaming: false });
      return;
    }

    setStatusBadge('翻译中...', 'pending');
    metaNode.textContent = `并行翻译：完成 ${progress.done}/${progress.total}，进行中 ${
      progress.running + progress.streaming
    }，等待 ${progress.pending}`;
    scheduleAdaptiveResize({
      allowShrink: false,
      streaming: progress.running + progress.streaming > 0
    });
    return;
  }

  if (payload.stage === 'service-update') {
    return;
  }

  if (payload.stage === 'translating' || payload.translation === '翻译中...') {
    maybeAutoPlaySourceText(sourceNode.textContent || '');
    resetTypingState();
    showSingleResultText(payload.translation || '翻译中...');
    setStatusBadge('翻译中...', 'pending');
    const serviceMeta = buildServiceMeta(payload);
    metaNode.textContent = serviceMeta
      ? `${serviceMeta} ｜ 正在处理，触发快捷键：${shortcutText}`
      : `正在处理，触发快捷键：${shortcutText}`;
    flushCountUpdate();
    scheduleAdaptiveResize({ allowShrink: false });
    return;
  }

  if (payload.stage === 'streaming') {
    setStatusBadge('流式输出中', 'pending');
    const serviceMeta = buildServiceMeta(payload);
    metaNode.textContent = serviceMeta
      ? `${serviceMeta} ｜ 译文正在逐字生成...`
      : '译文正在逐字生成...';
    queueTypingResult(payload.translation || '', { isFinal: false });
    scheduleAdaptiveResize({ allowShrink: false, streaming: true });
    return;
  }

  if (payload.stage === 'busy') {
    latestServiceResults = [];
    lastResizeSignature = '';
    resetTypingState();
    showSingleResultText(payload.translation || '（无译文）');
    setStatusBadge('任务进行中', 'pending');
    metaNode.textContent = payload.error || '已有翻译任务进行中';
    flushCountUpdate();
    scheduleAdaptiveResize({ allowShrink: true });
    return;
  }

  if (payload.error) {
    latestServiceResults = [];
    lastResizeSignature = '';
    stopAutoPlaySourceText();
    resetTypingState();
    showSingleResultText(payload.translation || '（无译文）');
    setStatusBadge('翻译失败', 'error');
    const serviceMeta = buildServiceMeta(payload);
    metaNode.textContent = serviceMeta ? `${serviceMeta} ｜ ${payload.error}` : payload.error;
    flushCountUpdate();
    scheduleAdaptiveResize({ allowShrink: true });
    return;
  }

  if (payload.stage === 'done') {
    maybeAutoCopyTranslation(payload);
  }

  setStatusBadge('流式输出中', 'pending');
  const serviceMeta = buildServiceMeta(payload);
  metaNode.textContent = serviceMeta ? `${serviceMeta} ｜ 译文正在逐字收尾...` : '译文正在逐字收尾...';
  queueTypingResult(payload.translation || '', { isFinal: true });
  scheduleAdaptiveResize({ allowShrink: true });
});

applyUiConfig();
updateCount();
