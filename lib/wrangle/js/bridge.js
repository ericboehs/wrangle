// Persistent JXA bridge for one scoped Safari window. Newline-delimited JSON on stdio.
// Every request names the window it expects. The bridge never searches for a replacement.
ObjC.import('AppKit');

const SAFARI_BUNDLE = 'com.apple.Safari';
const MAX_EVAL_RESULT = 4000000;
const POLL_SECONDS = 0.05;

// The page function and the observation thunk are code this bridge is given once, never per call.
const scripts = { page: null, snapshot: null };

const stdinHandle = $.NSFileHandle.fileHandleWithStandardInput;
const stdoutHandle = $.NSFileHandle.fileHandleWithStandardOutput;

const escapeNonAscii = (text) =>
  text.replace(/[\u007f-\uffff]/g, (character) => '\\u' + character.charCodeAt(0).toString(16).padStart(4, '0'));

function writeLine(value) {
  const line = escapeNonAscii(JSON.stringify(value)) + '\n';
  stdoutHandle.writeData($(line).dataUsingEncoding($.NSUTF8StringEncoding));
}

function fail(code, message) {
  const error = new Error(message);
  error.bridgeCode = code;
  return error;
}

function sleep(seconds) {
  $.NSThread.sleepForTimeInterval(seconds);
}

function safariInstances() {
  return ObjC.unwrap($.NSWorkspace.sharedWorkspace.runningApplications)
    .filter((application) => ObjC.unwrap(application.bundleIdentifier) === SAFARI_BUNDLE)
    .map((application) => application.processIdentifier);
}

function safariIsRunning() {
  return safariInstances().length > 0;
}

function safariApp(allowLaunch) {
  if (!allowLaunch && !safariIsRunning()) throw fail('safari_not_running', 'Safari is not running');
  const safari = Application(SAFARI_BUNDLE);
  safari.includeStandardAdditions = false;
  return safari;
}

function windowIds(safari) {
  const ids = [];
  for (const candidate of safari.windows()) {
    try {
      ids.push(candidate.id());
    } catch (error) {
      // A window that disappears mid-enumeration is simply not a candidate.
    }
  }
  return ids;
}

function windowById(safari, id) {
  const target = safari.windows.byId(id);
  try {
    target.id();
  } catch (error) {
    throw fail('window_gone', 'The scoped Safari window no longer exists');
  }
  return target;
}

// Apple Events cost about 17ms each, so the hot path reads unresolved specifiers and never more than it must.
function scopedTab(scope) {
  if (!scope || typeof scope.window_id !== 'number') throw fail('bad_request', 'A scope needs a window_id');
  const safari = safariApp(false);
  const target = safari.windows.byId(scope.window_id);
  const wantsUrl = typeof scope.url === 'string';
  let tabCount;
  let index;
  let url = null;
  try {
    tabCount = target.tabs.length;
    index = target.currentTab.index();
    if (wantsUrl) url = target.currentTab.url() || '';
  } catch (error) {
    throw fail('window_gone', 'The scoped Safari window no longer answers');
  }
  if (scope.mode === 'dedicated' && tabCount !== 1) {
    throw fail('scope_changed', `The dedicated Safari window now holds ${tabCount} tabs`);
  }
  if (typeof scope.tab_index === 'number' && index !== scope.tab_index) {
    throw fail('scope_changed', 'A different tab is now current in the scoped Safari window');
  }
  if (wantsUrl && url !== scope.url) {
    throw fail('scope_changed', 'The scoped Safari tab is showing a different page');
  }
  return { safari, target, tab: target.currentTab };
}

// AppKit measures y upward from the main screen's bottom-left; AppleScript measures it downward from its top-left.
function screenBounds(screen, mainHeight) {
  const frame = screen.visibleFrame;
  return {
    x: Math.round(frame.origin.x),
    y: Math.round(mainHeight - (frame.origin.y + frame.size.height)),
    width: Math.round(frame.size.width),
    height: Math.round(frame.size.height),
  };
}

function displays() {
  const screens = ObjC.unwrap($.NSScreen.screens);
  const mainHeight = screens.length ? screens[0].frame.size.height : 0;
  return screens.map((screen, index) => ({ display: index, main: index === 0, ...screenBounds(screen, mainHeight) }));
}

function boundsFor(request) {
  if (Array.isArray(request.bounds)) {
    const [x, y, width, height] = request.bounds;
    if (![x, y, width, height].every((value) => typeof value === 'number' && isFinite(value))) {
      throw fail('bad_request', 'bounds must be four finite numbers');
    }
    if (width <= 0 || height <= 0) throw fail('bad_request', 'bounds must have a positive size');
    return { x, y, width, height };
  }
  if (request.display === null || request.display === undefined) return null;
  const available = displays();
  const chosen = available[request.display];
  if (!chosen) throw fail('bad_request', `No display ${request.display}; ${available.length} attached`);
  const { x, y, width, height } = chosen;
  return { x, y, width, height };
}

// A window that is closing still appears in the element list but stops answering. It is not a usable target.
function readWindow(target) {
  try {
    const tabs = target.tabs();
    const tab = target.currentTab();
    if (!tabs || !tab) return null;
    const placement = target.bounds();
    return {
      window_id: target.id(),
      tabs: tabs.length,
      tab_index: tab.index(),
      bounds: [placement.x, placement.y, placement.width, placement.height],
      tab,
    };
  } catch (error) {
    return null;
  }
}

function tabFacts(target) {
  return {
    window_id: target.id(),
    tab_index: target.currentTab.index(),
    tabs: target.tabs.length,
    url: target.currentTab.url() || '',
    title: target.currentTab.name() || '',
  };
}

function runPageCode(safari, tab, code) {
  let result;
  try {
    result = safari.doJavaScript(code, { in: tab });
  } catch (error) {
    throw fail('javascript_failed', String(error && error.message ? error.message : error));
  }
  if (typeof result !== 'string') throw fail('bad_result', 'The page did not return a JSON string');
  if (result.length > MAX_EVAL_RESULT) throw fail('bad_result', 'The page result exceeded the size limit');
  return result;
}

function evaluate(request) {
  if (!scripts.page || !scripts.snapshot) throw fail('bad_request', 'Install the page scripts first');
  if (typeof request.payload !== 'string' || !request.payload) throw fail('bad_request', 'eval needs a payload');
  // The caller's payload is already JSON. It becomes one argument, never part of the program's structure.
  const code = `(${scripts.page})(${request.payload}, () => (${scripts.snapshot}))`;

  // Binding a document or mutating one is checked against Safari itself before the code is delivered.
  if (request.verify === true) {
    const { safari, tab } = scopedTab(request.scope);
    return { result: runPageCode(safari, tab, code) };
  }

  // A read pays for one guard event: the page epoch proves the document, this proves the user has not
  // reclaimed the window or switched away from the tab that was handed over.
  const scope = request.scope;
  if (!scope || typeof scope.window_id !== 'number') throw fail('bad_request', 'A scope needs a window_id');
  const safari = safariApp(false);
  const target = safari.windows.byId(scope.window_id);
  let tabCount = null;
  let index = null;
  try {
    if (scope.mode === 'dedicated') tabCount = target.tabs.length;
    else index = target.currentTab.index();
  } catch (error) {
    throw fail('window_gone', 'The scoped Safari window no longer answers');
  }
  if (tabCount !== null && tabCount !== 1) {
    throw fail('scope_changed', `The dedicated Safari window now holds ${tabCount} tabs`);
  }
  if (index !== null && typeof scope.tab_index === 'number' && index !== scope.tab_index) {
    throw fail('scope_changed', 'A different tab is now current in the scoped Safari window');
  }
  try {
    return { result: runPageCode(safari, target.currentTab, code) };
  } catch (error) {
    scopedTab(scope); // Turn an unclear failure into an accurate scope verdict when one exists.
    throw error;
  }
}

function openWindow(request) {
  if (typeof request.url !== 'string' || !request.url) throw fail('bad_request', 'open needs a url');
  const safari = safariApp(request.allow_launch !== false);
  const bounds = boundsFor(request);
  const before = new Set(windowIds(safari));
  const prior = request.restore_focus === false ? null : $.NSWorkspace.sharedWorkspace.frontmostApplication;

  safari.documents.push(safari.Document({ url: request.url }));

  let opened = null;
  const deadline = Date.now() + 10000;
  while (opened === null && Date.now() < deadline) {
    for (const id of windowIds(safari)) {
      if (!before.has(id)) {
        opened = id;
        break;
      }
    }
    if (opened === null) sleep(POLL_SECONDS);
  }
  if (opened === null) throw fail('open_failed', 'Safari did not report a new window');

  const target = windowById(safari, opened);
  if (bounds) target.bounds = bounds;
  // Give the keyboard back before waiting for the page; the agent window stays where it was put.
  if (prior) prior.activateWithOptions(0);

  const timeout = typeof request.timeout === 'number' && request.timeout > 0 ? request.timeout : 15;
  const loadDeadline = Date.now() + timeout * 1000;
  // A new window starts at about:blank, which is already readyState 'complete'. Waiting on
  // readiness alone therefore returns the blank document whenever the real page is slower than the
  // first poll. The tab's url is no help either: Safari updates it before the document is replaced,
  // so the two facts must be read from inside the same document to avoid racing each other.
  const wantsBlank = request.url === 'about:blank';
  const probe = wantsBlank
    ? "document.readyState === 'complete'"
    : "document.readyState === 'complete' && location.href !== 'about:blank'";
  let ready = false;
  while (!ready && Date.now() < loadDeadline) {
    try {
      ready = safari.doJavaScript(probe, { in: target.currentTab() }) === true;
    } catch (error) {
      throw fail('javascript_failed', String(error && error.message ? error.message : error));
    }
    if (!ready) sleep(POLL_SECONDS);
  }
  const placement = target.bounds();
  return {
    ...tabFacts(target),
    ready,
    bounds: [placement.x, placement.y, placement.width, placement.height],
  };
}

function handle(request) {
  switch (request.op) {
    case 'ping': {
      const instances = safariInstances();
      return {
        pid: $.NSProcessInfo.processInfo.processIdentifier,
        safari_running: instances.length > 0,
        // More than one Safari process makes window ids ambiguous, so the caller decides whether to proceed.
        safari_instances: instances.length,
      };
    }
    case 'scripts': {
      if (typeof request.page !== 'string' || typeof request.snapshot !== 'string') {
        throw fail('bad_request', 'scripts needs page and snapshot sources');
      }
      scripts.page = request.page;
      scripts.snapshot = request.snapshot;
      return { installed: true };
    }
    case 'displays':
      return { displays: displays() };
    case 'windows': {
      const safari = safariApp(false);
      const available = displays();
      const listed = [];
      for (const target of safari.windows()) {
        const facts = readWindow(target);
        if (!facts) continue;
        const [x, y, width, height] = facts.bounds;
        const centerX = x + width / 2;
        const centerY = y + height / 2;
        const display = available.findIndex(
          (screen) =>
            centerX >= screen.x &&
            centerX < screen.x + screen.width &&
            centerY >= screen.y &&
            centerY < screen.y + screen.height
        );
        const described = {
          window_id: facts.window_id,
          tabs: facts.tabs,
          tab_index: facts.tab_index,
          display: display < 0 ? null : display,
          bounds: facts.bounds,
        };
        // Titles and URLs identify a tab to its owner, so they are opt-in and never implied.
        listed.push(
          request.titles === true
            ? { ...described, url: facts.tab.url() || '', title: facts.tab.name() || '' }
            : described
        );
      }
      return { windows: listed };
    }
    case 'open':
      return openWindow(request);
    case 'attach': {
      const { target } = scopedTab({ window_id: request.window_id, mode: 'attach', url: request.url });
      return tabFacts(target);
    }
    case 'bounds': {
      const safari = safariApp(false);
      const target = windowById(safari, request.window_id);
      const bounds = boundsFor(request);
      if (!bounds) throw fail('bad_request', 'bounds needs a display or explicit bounds');
      target.bounds = bounds;
      const placement = target.bounds();
      return { bounds: [placement.x, placement.y, placement.width, placement.height] };
    }
    case 'eval':
      return evaluate(request);
    case 'close': {
      // Only a window this bridge opened may be closed, and only when the caller still owns it.
      if (request.owned !== true) throw fail('bad_request', 'Refusing to close a window this bridge does not own');
      const safari = safariApp(false);
      const target = windowById(safari, request.window_id);
      const facts = readWindow(target);
      if (!facts) return { closed: null };
      if (facts.tabs !== 1) throw fail('scope_changed', 'The owned window gained tabs; leaving it open');
      target.close();
      return { closed: request.window_id };
    }
    default:
      throw fail('bad_request', `Unknown operation ${request.op}`);
  }
}

function run() {
  let buffer = '';
  for (;;) {
    const data = stdinHandle.availableData;
    if (!data || data.length === 0) return;
    buffer += ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (!line.trim()) continue;
      let request = null;
      try {
        request = JSON.parse(line);
      } catch (error) {
        writeLine({ id: null, ok: false, code: 'bad_request', error: 'Request was not valid JSON' });
        continue;
      }
      if (request.op === 'exit') {
        writeLine({ id: request.id ?? null, ok: true, value: { exiting: true } });
        return;
      }
      try {
        writeLine({ id: request.id ?? null, ok: true, value: handle(request) });
      } catch (error) {
        writeLine({
          id: request.id ?? null,
          ok: false,
          code: error && error.bridgeCode ? error.bridgeCode : 'bridge_error',
          error: String(error && error.message ? error.message : error),
        });
      }
    }
  }
}
