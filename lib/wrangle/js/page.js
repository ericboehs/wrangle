// Runs inside the scoped Safari tab. Code-owned: the model never contributes JavaScript, only an observed action id.
// Receives the request as a JSON literal and `snapshot` as the shared observation thunk. Always returns a JSON string.
(request, snapshot) => {
  const reply = (value) => JSON.stringify(value);
  const observed = () => {
    const state = snapshot();
    return state ? reply({ status: 'ok', state }) : reply({ status: 'navigating' });
  };

  if (request.op === 'install') {
    const state = snapshot();
    if (!state) return reply({ status: 'navigating' });
    // snapshot() creates the cache; the epoch marks this exact document as the one the session bound to.
    window.__wrangle.epoch = request.epoch;
    return reply({ status: 'ok', state });
  }

  const cache = window.__wrangle;
  if (!cache || cache.epoch !== request.epoch) return reply({ status: 'epoch_lost' });

  if (request.op === 'observe') return observed();
  if (request.op === 'marker') {
    const state = snapshot();
    return state ? reply({ status: 'ok', marker: state.marker }) : reply({ status: 'navigating' });
  }
  if (request.op === 'guard') {
    const element = cache.nodes.get(request.node);
    return reply({ status: 'ok', guard: [cache.pageKey(), element ? cache.guard(element) : null] });
  }
  if (request.op === 'probe') return reply({ status: 'ok', act: cache.act || null });
  if (request.op !== 'act') return reply({ status: 'unsupported' });

  const action = request.action;
  if (action.kind === 'scroll') {
    cache.act = { nonce: request.nonce, kind: 'scroll', phase: 'started' };
    scrollBy({ top: action.delta, left: 0, behavior: 'instant' });
    cache.act.phase = 'finished';
    return reply({ status: 'executed' });
  }

  const element = cache.nodes.get(action.node);
  if (
    !element ||
    !element.isConnected ||
    element.matches(':disabled') ||
    element.closest('[aria-disabled="true"],[inert]') ||
    !element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
  ) {
    return reply({ status: 'blocked', reason: 'target' });
  }
  if (action.kind === 'fill' && (element.readOnly || element.getAttribute('aria-readonly') === 'true')) {
    return reply({ status: 'blocked', reason: 'readonly' });
  }
  const rect = element.getBoundingClientRect();
  const x = rect.x + rect.width / 2;
  const y = rect.y + rect.height / 2;
  if (!rect.width || !rect.height || x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) {
    return reply({ status: 'blocked', reason: 'offscreen' });
  }
  if (!element.contains(document.elementFromPoint(x, y))) return reply({ status: 'blocked', reason: 'covered' });
  if (action.kind === 'select') {
    const selectable =
      element.tagName === 'SELECT' &&
      [...element.options].some(
        (option) => option.value === action.value && !option.disabled && !option.closest('optgroup[disabled]')
      );
    if (!selectable) return reply({ status: 'blocked', reason: 'option' });
  }

  // From here a mutation is about to happen. The nonce lets the caller learn how far it got if the bridge dies.
  cache.act = { nonce: request.nonce, kind: action.kind, phase: 'started' };

  if (action.kind === 'select') {
    element.value = action.value;
    element.dispatchEvent(new Event('input', { bubbles: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
    cache.act.phase = 'finished';
    return reply({ status: element.value === action.value ? 'executed' : 'unconfirmed' });
  }

  if (action.kind === 'fill') {
    const text = request.text;
    element.focus({ preventScroll: true });
    if (element.isContentEditable) {
      element.textContent = text;
    } else {
      const prototype =
        element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
      if (setter) setter.call(element, text);
      else element.value = text;
    }
    element.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
    cache.act.phase = 'finished';
    const current = element.isContentEditable ? element.textContent : element.value;
    return reply({ status: current === text ? 'executed' : 'unconfirmed' });
  }

  const pointer = {
    bubbles: true,
    cancelable: true,
    composed: true,
    view: window,
    detail: 1,
    clientX: x,
    clientY: y,
    button: 0,
    pointerId: 1,
    pointerType: 'mouse',
    isPrimary: true,
  };
  if (typeof element.focus === 'function' && element.tabIndex >= 0) element.focus({ preventScroll: true });
  element.dispatchEvent(new PointerEvent('pointerdown', { ...pointer, buttons: 1 }));
  element.dispatchEvent(new MouseEvent('mousedown', { ...pointer, buttons: 1 }));
  element.dispatchEvent(new PointerEvent('pointerup', { ...pointer, buttons: 0 }));
  element.dispatchEvent(new MouseEvent('mouseup', { ...pointer, buttons: 0 }));
  element.click();
  cache.act.phase = 'finished';
  return reply({ status: 'executed' });
}
