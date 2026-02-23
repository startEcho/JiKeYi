const { getRuntimeConfig } = require('./config');

const TRANSLATION_CACHE_LIMIT = 200;
const GLOSSARY_LIMIT = 120;
const translationCache = new Map();

function buildEndpoint(baseUrl) {
  return `${baseUrl.replace(/\/$/, '')}/v1/messages`;
}

function normalizeInputText(text) {
  return String(text || '').trim();
}

function normalizeTimeoutMs(value, fallback = 60000) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return Math.floor(parsed);
}

function normalizeGlossary(rawGlossary = []) {
  if (!Array.isArray(rawGlossary)) {
    return [];
  }

  const dedupe = new Set();
  const result = [];
  for (const item of rawGlossary.slice(0, GLOSSARY_LIMIT)) {
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

function buildGlossarySignature(glossary) {
  if (!Array.isArray(glossary) || glossary.length === 0) {
    return '';
  }
  return glossary.map((item) => `${item.source}=>${item.target}`).join('|');
}

function resolveRequestConfig(options = {}) {
  const runtimeConfig = options.runtimeConfig || getRuntimeConfig();
  const serviceConfig = options.serviceConfig || {};

  const baseUrl = String(serviceConfig.baseUrl || runtimeConfig.baseUrl || '').trim();
  const apiKey = String(serviceConfig.apiKey || runtimeConfig.apiKey || '').trim();
  const model = String(serviceConfig.model || runtimeConfig.model || '').trim();
  const targetLanguage = String(
    serviceConfig.targetLanguage || runtimeConfig.targetLanguage || '简体中文'
  ).trim();
  const timeoutMs = normalizeTimeoutMs(
    serviceConfig.timeoutMs || runtimeConfig.timeoutMs,
    60000
  );
  const serviceId = String(
    options.serviceId || serviceConfig.id || runtimeConfig.activeServiceId || ''
  ).trim();
  const serviceName = String(
    options.serviceName || serviceConfig.name || runtimeConfig.activeServiceName || ''
  ).trim();
  const glossary = normalizeGlossary(
    Array.isArray(options.glossary) ? options.glossary : runtimeConfig.glossary || []
  );

  return {
    baseUrl,
    apiKey,
    model,
    targetLanguage,
    timeoutMs,
    serviceId,
    serviceName,
    glossary
  };
}

function ensureConfig(config) {
  if (!config.baseUrl || !config.apiKey || !config.model) {
    throw new Error(
      '配置不完整：请在 settings.json 中设置 ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN / ANTHROPIC_MODEL'
    );
  }
}

function buildCacheKey(config, text) {
  return [
    config.baseUrl,
    config.model,
    config.targetLanguage,
    buildGlossarySignature(config.glossary),
    text
  ].join('\u0001');
}

function readCachedTranslation(cacheKey) {
  if (!translationCache.has(cacheKey)) {
    return '';
  }

  const value = translationCache.get(cacheKey);
  translationCache.delete(cacheKey);
  translationCache.set(cacheKey, value);
  return value;
}

function writeCachedTranslation(cacheKey, translatedText) {
  const text = String(translatedText || '').trim();
  if (!text) {
    return;
  }

  translationCache.set(cacheKey, text);

  if (translationCache.size <= TRANSLATION_CACHE_LIMIT) {
    return;
  }

  const oldestKey = translationCache.keys().next().value;
  if (oldestKey) {
    translationCache.delete(oldestKey);
  }
}

function estimateMaxTokens(text) {
  const charCount = Array.from(text).length;
  if (charCount <= 72) {
    return 128;
  }
  const estimated = Math.round(charCount * 1.12) + 72;
  return Math.min(560, Math.max(96, estimated));
}

function buildSystemPrompt(config) {
  const basePrompt = `翻译为${config.targetLanguage}。只输出译文，不要解释；保留原有换行、列表、代码标记、URL、数字与大小写。`;
  if (!Array.isArray(config.glossary) || config.glossary.length === 0) {
    return basePrompt;
  }

  const glossaryLines = config.glossary.map((item) => `${item.source} => ${item.target}`).join('\n');
  return `${basePrompt}

术语表（命中时优先使用右侧译法）：
${glossaryLines}
`;
}

function buildRequestBody(config, text, stream) {
  const normalizedText = normalizeInputText(text);

  return {
    model: config.model,
    max_tokens: estimateMaxTokens(normalizedText),
    temperature: 0,
    stream: Boolean(stream),
    system: buildSystemPrompt(config),
    messages: [
      {
        role: 'user',
        content: normalizedText
      }
    ]
  };
}

function extractTextFromMessageResponse(data) {
  return data?.content
    ?.filter((part) => part.type === 'text')
    ?.map((part) => part.text)
    ?.join('\n')
    ?.trim();
}

function parseSseBlock(block) {
  const lines = block.split(/\r?\n/);
  let event = 'message';
  const dataLines = [];

  for (const line of lines) {
    if (line.startsWith('event:')) {
      event = line.slice(6).trim();
      continue;
    }

    if (line.startsWith('data:')) {
      dataLines.push(line.slice(5).trim());
    }
  }

  return {
    event,
    dataText: dataLines.join('\n')
  };
}

function findSseDelimiter(buffer) {
  const rnIndex = buffer.indexOf('\r\n\r\n');
  const nnIndex = buffer.indexOf('\n\n');

  if (rnIndex === -1) {
    return {
      index: nnIndex,
      length: nnIndex === -1 ? 0 : 2
    };
  }

  if (nnIndex === -1 || rnIndex < nnIndex) {
    return {
      index: rnIndex,
      length: 4
    };
  }

  return {
    index: nnIndex,
    length: 2
  };
}

function toErrorMessage(payload) {
  return payload?.error?.message || payload?.message || payload?.error || '流式翻译请求失败';
}

function buildServiceError(config, message, extra = {}) {
  const error = new Error(message);
  error.serviceId = config.serviceId;
  error.serviceName = config.serviceName;
  Object.assign(error, extra);
  return error;
}

function rethrowWithServiceMeta(config, error) {
  if (error?.name === 'AbortError') {
    throw buildServiceError(config, `请求超时（${config.timeoutMs}ms）`, {
      code: 'TIMEOUT',
      isTimeout: true
    });
  }

  if (error instanceof Error) {
    if (!error.serviceId) {
      error.serviceId = config.serviceId;
    }
    if (!error.serviceName) {
      error.serviceName = config.serviceName;
    }
    throw error;
  }

  throw buildServiceError(config, String(error || '请求失败'));
}

async function translateText(text, options = {}) {
  const config = resolveRequestConfig(options);
  ensureConfig(config);
  const normalizedText = normalizeInputText(text);
  if (!normalizedText) {
    return '';
  }

  const cacheKey = buildCacheKey(config, normalizedText);
  const cached = readCachedTranslation(cacheKey);
  if (cached) {
    return cached;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => {
    controller.abort();
  }, config.timeoutMs);

  try {
    const response = await fetch(buildEndpoint(config.baseUrl), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': config.apiKey,
        Authorization: `Bearer ${config.apiKey}`,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify(buildRequestBody(config, normalizedText, false)),
      signal: controller.signal
    });

    if (!response.ok) {
      const detail = await response.text();
      throw buildServiceError(config, `翻译请求失败（${response.status}）：${detail}`, {
        statusCode: response.status
      });
    }

    const data = await response.json();
    const translated = extractTextFromMessageResponse(data);

    if (!translated) {
      throw buildServiceError(config, '接口返回为空，未获取到译文');
    }

    const finalText = translated.trim();
    writeCachedTranslation(cacheKey, finalText);
    return finalText;
  } catch (error) {
    rethrowWithServiceMeta(config, error);
  } finally {
    clearTimeout(timeout);
  }
}

async function streamTranslateText(text, handlers = {}, options = {}) {
  const config = resolveRequestConfig(options);
  ensureConfig(config);
  const normalizedText = normalizeInputText(text);
  if (!normalizedText) {
    return '';
  }

  const cacheKey = buildCacheKey(config, normalizedText);
  const cached = readCachedTranslation(cacheKey);
  if (cached) {
    handlers.onDelta?.(cached, cached);
    return cached;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => {
    controller.abort();
  }, config.timeoutMs);

  let fullText = '';

  try {
    const response = await fetch(buildEndpoint(config.baseUrl), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': config.apiKey,
        Authorization: `Bearer ${config.apiKey}`,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify(buildRequestBody(config, normalizedText, true)),
      signal: controller.signal
    });

    if (!response.ok) {
      const detail = await response.text();
      throw buildServiceError(config, `流式翻译请求失败（${response.status}）：${detail}`, {
        statusCode: response.status
      });
    }

    if (!response.body) {
      throw buildServiceError(config, '流式响应体为空');
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder('utf-8');
    let buffer = '';

    const consumeBlock = (block) => {
      const { event, dataText } = parseSseBlock(block);
      if (!dataText) {
        return false;
      }

      if (dataText === '[DONE]') {
        return true;
      }

      let payload;
      try {
        payload = JSON.parse(dataText);
      } catch {
        return false;
      }

      if (event === 'error' || payload?.type === 'error') {
        throw buildServiceError(config, toErrorMessage(payload));
      }

      if (payload?.type === 'content_block_start' && payload?.content_block?.type === 'text') {
        const startText = payload.content_block.text || '';
        if (startText) {
          fullText += startText;
          handlers.onDelta?.(fullText, startText);
        }
        return false;
      }

      if (payload?.type === 'content_block_delta' && payload?.delta?.type === 'text_delta') {
        const delta = payload.delta.text || '';
        if (delta) {
          fullText += delta;
          handlers.onDelta?.(fullText, delta);
        }
      }

      return false;
    };

    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }

      buffer += decoder.decode(value, { stream: true });

      while (true) {
        const delimiter = findSseDelimiter(buffer);
        if (delimiter.index === -1) {
          break;
        }

        const block = buffer.slice(0, delimiter.index).trim();
        buffer = buffer.slice(delimiter.index + delimiter.length);
        if (!block) {
          continue;
        }

        const finished = consumeBlock(block);
        if (finished) {
          break;
        }
      }
    }

    if (!fullText.trim()) {
      throw buildServiceError(config, '流式接口返回为空，未获取到译文');
    }

    const finalText = fullText.trim();
    writeCachedTranslation(cacheKey, finalText);
    return finalText;
  } catch (error) {
    rethrowWithServiceMeta(config, error);
  } finally {
    clearTimeout(timeout);
  }
}

module.exports = {
  translateText,
  streamTranslateText
};
